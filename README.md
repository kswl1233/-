# 安徽理工大学校园网自动登录工具

这是一个 Windows 校园网自动登录工具。配置一次后，电脑每次登录 Windows 会自动尝试连接校园网认证网关。

适用登录页：

```text
http://10.255.0.19/
```

## 推荐用法

双击运行：

```text
Start-CampusNet-GUI.cmd
```

在界面里填写：

- 学号/工号
- 密码
- 出口类型

然后点击：

```text
保存并开启自动登录
```

配置成功后，之后开机或登录 Windows 会自动联网。

## 出口说明

界面中的出口对应学校网关实际账号后缀：

| 界面选项 | 实际提交格式 |
| --- | --- |
| 学生电信出口 | `学号@aust` |
| 学生联通出口 | `学号@unicom` |
| 学生移动出口 | `学号@cmcc` |
| 教职工出口 | `工号@jzg` |

如果不确定选哪个，选择你自己办理过互联网访问业务的运营商出口。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `Start-CampusNet-GUI.cmd` | 双击打开图形界面，推荐普通同学使用 |
| `campus-net-gui.ps1` | 图形界面配置器 |
| `campus-net-login.ps1` | 后台自动登录脚本，开机任务会调用它 |
| `setup-campus-net.ps1` | 命令行配置脚本，备用 |
| `README.md` | 本说明文档 |

## 图形界面按钮

### 读取网页登录项

在校园网环境下读取登录页字段和出口选项。一般第一次配置时可以点一下。

### 保存并开启自动登录

保存账号、密码、出口，并创建 Windows 计划任务。

### 测试登录

立即运行一次登录脚本，用来确认配置是否可用。

### 删除自动登录

删除开机自动登录任务，不会删除脚本文件。

### 打开日志

打开登录日志，排查失败原因。

## 自动登录位置

配置会保存到：

```text
%LOCALAPPDATA%\CampusNetAutoLogin
```

主要文件：

```text
%LOCALAPPDATA%\CampusNetAutoLogin\campus-net-config.json
%LOCALAPPDATA%\CampusNetAutoLogin\campus-net-login.ps1
%LOCALAPPDATA%\CampusNetAutoLogin\login.log
```

密码不是明文保存，而是用当前 Windows 用户加密保存。通常只有同一台电脑上的同一个 Windows 用户能解密。

## 查看日志

图形界面里点“打开日志”，或在 PowerShell 里运行：

```powershell
Get-Content "$env:LOCALAPPDATA\CampusNetAutoLogin\login.log" -Tail 50
```

常见成功日志类似：

```text
Eportal response result=1 msg=认证成功
Login accepted by gateway.
```

## 重新配置

直接重新双击：

```text
Start-CampusNet-GUI.cmd
```

重新填写后点击“保存并开启自动登录”即可覆盖旧配置。

## 删除自动登录

在图形界面里点击“删除自动登录”。

也可以用 PowerShell 删除：

```powershell
Unregister-ScheduledTask -TaskName CampusNetAutoLogin -Confirm:$false
```

如需同时删除本机配置：

```powershell
Remove-Item "$env:LOCALAPPDATA\CampusNetAutoLogin" -Recurse -Force
```

## 常见问题

### 日志显示 404

如果看到：

```text
远程服务器返回错误: (404) 未找到
```

通常表示登录接口写错或脚本不是最新版本。当前版本应使用：

```text
http://10.255.0.19:801/eportal/?c=Portal&a=login
```

重新运行图形界面并保存一次，或确认 `%LOCALAPPDATA%\CampusNetAutoLogin\campus-net-login.ps1` 已更新。

### 日志显示认证失败

请检查：

- 学号/工号是否正确
- 密码是否正确
- 出口是否选对
- 账号是否已开通对应运营商的互联网访问业务

### 开机后没有自动登录

检查计划任务是否存在：

```powershell
Get-ScheduledTask -TaskName CampusNetAutoLogin
```

如果不存在，重新打开图形界面并点击“保存并开启自动登录”。

### 想手动测试一次

在图形界面点击“测试登录”。

或运行：

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\CampusNetAutoLogin\campus-net-login.ps1" -ConfigPath "$env:LOCALAPPDATA\CampusNetAutoLogin\campus-net-config.json" -MaxAttempts 1
```

## 高级说明

本工具针对安徽理工大学 Dr.COM / ePortal 网关做了快速登录适配：

- 使用 `/drcom/chkstatus` 快速判断是否已在线
- 使用 `:801/eportal/?c=Portal&a=login` 提交认证
- 默认开机登录后约 5 秒开始运行
- 默认失败后每 2 秒重试一次

普通使用不需要修改高级设置。

## 开源协议

本项目使用 MIT License。详见 `LICENSE`。

## 免责声明

本工具仅用于简化个人校园网登录流程，不会绕过学校认证，也不会破解或获取他人账号。请遵守学校网络使用规定，并妥善保管自己的账号和密码。
