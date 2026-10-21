#!/usr/bin/env python3
"""Host regression for the actual JNI launcher; no Android TUN or VPN is used."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class NativeProcessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="qingzhou-native-process-")
        cls.root = Path(cls.temp.name)
        (cls.root / "android").mkdir()
        (cls.root / "jni.h").write_text("""
#define JNIEXPORT
#define JNICALL
using jint = int;
using jobject = void*;
using jstring = const char*;
struct JNIEnv {
    const char* GetStringUTFChars(jstring s, void*) { return s; }
    void ReleaseStringUTFChars(jstring, const char*) {}
};
""")
        (cls.root / "android/log.h").write_text("""
#define ANDROID_LOG_ERROR 6
inline int __android_log_print(int, const char*, const char*, ...) { return 0; }
""")
        (cls.root / "fixture.cpp").write_text(r'''
#include <jni.h>
#include <cassert>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <thread>
#include <sys/wait.h>
#include <unistd.h>
extern "C" int Java_dev_splitvpn_android_SplitVpnService_startTun2SocksNative(JNIEnv*, void*, const char*, int, const char*, int, const char*);
extern "C" int Java_dev_splitvpn_android_SplitVpnService_nativeProcessStatus(JNIEnv*, void*, int);
extern "C" int Java_dev_splitvpn_android_SplitVpnService_waitForNativeProcessExit(JNIEnv*, void*, int);
extern "C" void Java_dev_splitvpn_android_SplitVpnService_stopNativeProcess(JNIEnv*, void*, int);
int main(int argc, char** argv) {
    if (argc > 1 && strcmp(argv[1], "-device") == 0) {
        if (fcntl(3, F_GETFD) != 0) return 90;
        if (argc != 9 || strcmp(argv[7], "-loglevel") != 0 || strcmp(argv[8], "warn") != 0) return 91;
        if (getenv("QZ_FIXTURE_EXIT")) { usleep(150000); return 42; }
        sleep(60);
        return 0;
    }
    assert(argc == 3);
    JNIEnv env;
    int tun = open("/dev/null", O_RDONLY);
    assert(tun >= 0);
    const char* binary = argv[0];
    if (strcmp(argv[1], "missing") == 0) binary = "/nonexistent/qingzhou-fixture";
    if (strcmp(argv[1], "not-executable") == 0) binary = argv[2];
    if (strcmp(argv[1], "invalid-fd") == 0) { close(tun); tun = -1; }
    if (strcmp(argv[1], "exit") == 0 || strcmp(argv[1], "watch-exit") == 0) setenv("QZ_FIXTURE_EXIT", "1", 1);
    int pid = Java_dev_splitvpn_android_SplitVpnService_startTun2SocksNative(&env, nullptr, binary, tun, "socks5://127.0.0.1:9", 1500, "/dev/null");
    if (strcmp(argv[1], "missing") == 0) assert(pid == -ENOENT);
    else if (strcmp(argv[1], "not-executable") == 0) assert(pid == -EACCES);
    else if (strcmp(argv[1], "invalid-fd") == 0) assert(pid == -EBADF);
    else {
        assert(pid > 0);
        assert(Java_dev_splitvpn_android_SplitVpnService_nativeProcessStatus(&env, nullptr, pid) == 0);
        if (strcmp(argv[1], "exit") == 0) {
            usleep(300000);
            assert(Java_dev_splitvpn_android_SplitVpnService_nativeProcessStatus(&env, nullptr, pid) == 43);
        }
        if (strcmp(argv[1], "watch-exit") == 0) {
            assert(Java_dev_splitvpn_android_SplitVpnService_waitForNativeProcessExit(&env, nullptr, pid) == 43);
            // The watcher must leave reaping to the lifecycle queue.
            assert(Java_dev_splitvpn_android_SplitVpnService_nativeProcessStatus(&env, nullptr, pid) == 43);
        }
        if (strcmp(argv[1], "watch-stop") == 0) {
            std::thread watcher([&] {
                int status = Java_dev_splitvpn_android_SplitVpnService_waitForNativeProcessExit(&env, nullptr, pid);
                assert(status != 0);
            });
            Java_dev_splitvpn_android_SplitVpnService_stopNativeProcess(&env, nullptr, pid);
            watcher.join();
        }
        Java_dev_splitvpn_android_SplitVpnService_stopNativeProcess(&env, nullptr, pid);
        assert(waitpid(pid, nullptr, WNOHANG) == -1 && errno == ECHILD);
    }
    if (tun >= 0) close(tun);
    assert(waitpid(-1, nullptr, WNOHANG) == -1 && errno == ECHILD);
}
''')
        cls.binary = cls.root / "fixture"
        cls.non_executable = cls.root / "not-executable"
        cls.non_executable.write_text("fixture")
        cls.non_executable.chmod(0o600)
        source = Path(__file__).resolve().parents[1] / "app/src/main/cpp/tunfdexec.cpp"
        subprocess.run([os.environ.get("CXX", "c++"), "-std=c++17", "-pthread", "-Wall", "-Wextra", "-Werror", "-I", str(cls.root),
                        str(cls.root / "fixture.cpp"), str(source), "-o", str(cls.binary)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def check(self, mode):
        subprocess.run([str(self.binary), mode, str(self.non_executable)], check=True, timeout=8)

    def test_missing_binary_reports_exec_failure(self):
        self.check("missing")

    def test_exec_permission_failure_is_not_connected(self):
        self.check("not-executable")

    def test_invalid_tun_fd_reports_dup_failure(self):
        self.check("invalid-fd")

    def test_child_exit_is_observed_and_reaped(self):
        self.check("exit")

    def test_child_survives_exec_and_stops_without_a_zombie(self):
        self.check("stop")

    def test_blocking_exit_watcher_leaves_reaping_to_lifecycle(self):
        self.check("watch-exit")

    def test_stop_and_watcher_can_race_without_a_zombie(self):
        self.check("watch-stop")


if __name__ == "__main__":
    unittest.main()
