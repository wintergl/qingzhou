#include <jni.h>
#include <android/log.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef __linux__
#include <sys/prctl.h>
#endif

namespace {

constexpr int kTunFd = 3;
constexpr const char* kTag = "splitvpn-native";
constexpr int kExecTimeoutMs = 5000;

// Returns zero only while this child is alive, and reaps terminated children.
int process_status(pid_t pid) {
    int status = 0;
    pid_t result;
    do { result = waitpid(pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
    if (result == 0) return 0;
    if (result < 0) return 256 + errno;
    if (WIFEXITED(status)) return 1 + WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 256;
}

void kill_and_reap(pid_t pid) {
    kill(pid, SIGKILL);
    while (waitpid(pid, nullptr, 0) < 0 && errno == EINTR) {}
}

class JString {
public:
    JString(JNIEnv* env, jstring value) : env_(env), value_(value), chars_(nullptr) {
        if (value_ != nullptr) {
            chars_ = env_->GetStringUTFChars(value_, nullptr);
        }
    }

    ~JString() {
        if (chars_ != nullptr) {
            env_->ReleaseStringUTFChars(value_, chars_);
        }
    }

    const char* c_str() const {
        return chars_ == nullptr ? "" : chars_;
    }

private:
    JNIEnv* env_;
    jstring value_;
    const char* chars_;
};

void redirect_output_to_log(const char* log_path) {
    int log_fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR);
    if (log_fd < 0) {
        return;
    }
    dup2(log_fd, STDOUT_FILENO);
    dup2(log_fd, STDERR_FILENO);
    if (log_fd > STDERR_FILENO) {
        close(log_fd);
    }
}

} // namespace

extern "C" JNIEXPORT jint JNICALL
Java_dev_splitvpn_android_SplitVpnService_startTun2SocksNative(
    JNIEnv* env,
    jobject,
    jstring binary_path,
    jint tun_fd,
    jstring proxy_url,
    jint mtu,
    jstring log_path
) {
    JString binary(env, binary_path);
    JString proxy(env, proxy_url);
    JString log(env, log_path);

    // Close-on-exec EOF acknowledges successful exec; an errno reports failure.
    // Keep the write end above fd 3, which the child uses for the TUN.
    int pipe_fds[2];
    if (pipe(pipe_fds) < 0) return -errno;
    int error_fd = fcntl(pipe_fds[1], F_DUPFD_CLOEXEC, kTunFd + 1);
    int saved_error = errno;
    close(pipe_fds[1]);
    if (error_fd < 0) {
        close(pipe_fds[0]);
        return -saved_error;
    }
    fcntl(pipe_fds[0], F_SETFD, FD_CLOEXEC);
    char mtu_text[16];
    snprintf(mtu_text, sizeof(mtu_text), "%d", mtu);

    const pid_t parent_pid = getpid();
    pid_t pid = fork();
    if (pid < 0) {
        saved_error = errno;
        __android_log_print(ANDROID_LOG_ERROR, kTag, "fork failed: %s", strerror(saved_error));
        close(pipe_fds[0]);
        close(error_fd);
        return -saved_error;
    }

    if (pid == 0) {
#ifdef __linux__
        // Do not retain an orphan TUN fd after Android kills the service process.
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid() != parent_pid) _exit(125);
#else
        (void)parent_pid;
#endif
        close(pipe_fds[0]);
        redirect_output_to_log(log.c_str());

        if ((tun_fd != kTunFd && dup2(tun_fd, kTunFd) < 0) || fcntl(kTunFd, F_SETFD, 0) < 0) {
            int failure = errno;
            while (write(error_fd, &failure, sizeof(failure)) < 0 && errno == EINTR) {}
            _exit(126);
        }

        execl(
            binary.c_str(),
            binary.c_str(),
            "-device",
            "fd://3",
            "-proxy",
            proxy.c_str(),
            "-mtu",
            mtu_text,
            "-loglevel",
            "warn",
            static_cast<char*>(nullptr)
        );

        int failure = errno;
        while (write(error_fd, &failure, sizeof(failure)) < 0 && errno == EINTR) {}
        _exit(127);
    }

    close(error_fd);
    pollfd ready{pipe_fds[0], POLLIN | POLLHUP, 0};
    int result;
    do { result = poll(&ready, 1, kExecTimeoutMs); } while (result < 0 && errno == EINTR);
    int failure = result == 0 ? ETIMEDOUT : errno;
    ssize_t bytes = -1;
    if (result > 0) {
        do { bytes = read(pipe_fds[0], &failure, sizeof(failure)); } while (bytes < 0 && errno == EINTR);
        if (bytes < 0) failure = errno;
    }
    close(pipe_fds[0]);
    if (bytes != 0) {
        kill_and_reap(pid);
        return -failure;
    }
    if (process_status(pid) != 0) return -ECHILD;
    return static_cast<jint>(pid);
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_splitvpn_android_SplitVpnService_nativeProcessStatus(JNIEnv*, jobject, jint pid) {
    return pid <= 0 ? 256 + ECHILD : process_status(static_cast<pid_t>(pid));
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_splitvpn_android_SplitVpnService_waitForNativeProcessExit(JNIEnv*, jobject, jint pid) {
    if (pid <= 0) return 256 + ECHILD;
    siginfo_t info{};
    int result;
    // Observe without reaping. Only the lifecycle queue reaps/signals children,
    // so a watcher cannot release a PID just before stopNativeProcess signals it.
    do { result = waitid(P_PID, static_cast<id_t>(pid), &info, WEXITED | WNOWAIT); } while (result < 0 && errno == EINTR);
    if (result < 0) return 256 + errno;
    if (info.si_code == CLD_EXITED) return 1 + info.si_status;
    if (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED) return 128 + info.si_status;
    return 256;
}

extern "C" JNIEXPORT void JNICALL
Java_dev_splitvpn_android_SplitVpnService_stopNativeProcess(JNIEnv*, jobject, jint pid) {
    if (pid <= 0 || process_status(static_cast<pid_t>(pid)) != 0) {
        return;
    }
    kill(static_cast<pid_t>(pid), SIGTERM);
    for (int attempt = 0; attempt < 10; ++attempt) {
        if (process_status(static_cast<pid_t>(pid)) != 0) return;
        usleep(100 * 1000);
    }
    kill_and_reap(static_cast<pid_t>(pid));
}
