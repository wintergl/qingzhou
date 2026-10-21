namespace Qingzhou;

// UI validation only; the shared authentication helper enforces server policies.
sealed record CompanyPasswordChangeInput(string OldPassword, string NewPassword, string Confirmation, string NewUsername = "")
{
    public string? ValidationMessage(bool requireUsername)
    {
        if (requireUsername && NewUsername.Trim().Length == 0) return "请填写新账号名。";
        if (OldPassword.Length == 0 || NewPassword.Length == 0 || Confirmation.Length == 0) return "请填写旧密码、新密码和确认密码。";
        if (NewPassword != Confirmation) return "两次输入的新密码不一致。";
        if (NewPassword == OldPassword) return "新密码不能与旧密码相同。";
        // .NET string.Length counts UTF-16 code units, matching the official form.
        if (OldPassword.Length > 128 || NewPassword.Length > 128 || requireUsername && NewUsername.Trim().Length > 128)
            return "账号名和密码不能超过 128 个字符。";
        return null;
    }
}
