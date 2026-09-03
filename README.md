# 《心灵杀手 2》中文多字体自愈启动器

让《Alan Wake 2》同时拥有“直接进入中文”的方便和多字体补丁的完整字形，并在游戏更新覆盖文件后自动重建补丁。

> 本项目只提供自动化工具，不提供或转载游戏文件、汉化文本、字体文件。使用者必须拥有正版游戏，并自行合法取得相应补丁资源。

## 它解决什么问题

常见的中文补丁需要先切到别的语言，再切回中文才能生效；直接覆盖某个现有语言又可能导致字体不全、设置下拉框或游戏内 UI 变空。本工具采用下面的组合方式：

- 把中文字符串按键名合并到英语文本槽，新增的官方文本会暂时回退为英语，不会整段消失；
- 把 14 个多字体资源写入 `base-generic`，覆盖菜单、字幕、手写体、终端体等不同 UI 场景；
- 设置里的“英语”显示为“中文（修订多字体／英语语音）”，选择一次后可直接生效；
- 每次启动先比较哈希。没有变化就直接启动；检测到游戏更新才离线重建；
- 写入前完整暂存并验证，失败时自动回滚，最多保留两份备份；
- 每 24 小时最多检查一次 GitHub Release，有新版时验证 SHA-256 后自动更新工具本身。

## 下载与安装

1. 从右侧 **Releases** 下载最新的 `AlanWake2-Chinese-SelfHealing-v*.zip` 并解压到固定目录。
2. 准备你自己合法取得并解包的两类资源：
   - 汉化补丁中的 `string_table.bin`；
   - 多字体补丁目录，里面应能递归找到下列 14 个字体文件。
3. 右键 `Setup.ps1`，选择“使用 PowerShell 运行”；依次选择游戏目录、字符串表和字体目录。
4. 安装向导会完成首次修复，并在桌面创建“心灵杀手2 中文自愈启动器”。以后从这个快捷方式启动。

如果 Windows 阻止直接运行脚本，可在解压目录打开 PowerShell，执行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup.ps1
```

也可完全使用参数安装：

```powershell
.\Setup.ps1 `
  -GameRoot 'D:\Programs\AlanWake2' `
  -StringTablePath 'D:\Mods\ZHCN\string_table.bin' `
  -FontSourceRoot 'D:\Mods\FontPack'
```

## 所需字体文件

```text
aktivgroteskcd_bd.ttf
aktivgroteskcd_it.ttf
aktivgroteskcd_md.ttf
aktivgroteskcd_rg.ttf
aktivgroteskex_bd.ttf
aktivgroteskex_blk.ttf
aktivgroteskex_it.ttf
aktivgroteskex_md.ttf
aktivgroteskex_rg.ttf
bestten-crt.otf
digitalnumbers-regular.ttf
pressstart2p-regular.ttf
feltpenpro-medium.otf
prestige12pitchbt-bold.ttf
```

安装向导会递归查找这些文件；每个文件必须恰好出现一次。它们只会复制到你的本机安装目录，不会上传。

## 使用和排错

- 正常启动：双击桌面快捷方式。
- 只修复、不启动游戏：运行 `Start-AlanWake2-Chinese.ps1 -RepairOnly`。
- 只检查是否需要修复：运行 `Start-AlanWake2-Chinese.ps1 -AuditOnly`；退出代码 `0` 表示正常，`2` 表示需要修复。
- 日志：`logs/launcher.log`。
- 备份：`backups/`，自动只保留最近两份。
- 更换汉化或字体：重新运行 `Setup.ps1` 选择新资源。

修复时必须先退出游戏，也应等待 Epic 完成更新。脚本只有在实际写游戏目录时才请求管理员权限。

## 更新后的兼容策略

游戏更新后，旧汉化未必包含新文本。工具以更新后的官方英语表为骨架，按键名和重复出现顺序合并中文：

- 已有键继续使用中文；
- 新增键保留官方英语；
- 官方删除的键不会被强行塞回；
- 重复键不会因为普通字典合并而丢失。

这能避免更新后整个菜单或下拉框无字，但不能凭空翻译新剧情。汉化作者发布新版后，重新运行 `Setup.ps1` 换入新版 `string_table.bin` 即可。

## 安全边界

- 不会修改游戏可执行文件，也不注入进程；
- 修改目标仅为 `base-generic` 与 `base-en` 的 TOC/Blob 数据；
- 暂存阶段若检测到 Epic 又改动了资源，会在写入前中止；
- 写入失败会恢复 TOC、英语 Blob，并截断已追加的字体 Blob；
- 自动更新仅接受本仓库 GitHub Release，并校验随 Release 发布的 SHA-256。

仍建议先使用 Epic 的“验证文件”功能作为彻底还原手段。任何非官方修改都有风险，请自行备份存档并承担使用后果。

## 开发与发布

本项目面向 Windows PowerShell 5.1 和 .NET Framework 4.8。

```powershell
dotnet build .\src\RmdtocTool\Aw2Rmdtoc.csproj -c Release
powershell.exe -NoProfile -File .\tests\Test-Repository.ps1
```

推送会触发 Windows CI，编译 `Aw2Rmdtoc.dll`、检查 PowerShell 语法与仓库中是否误入资源文件，并生成可下载构件。合并到 `main` 后，若 `VERSION` 尚未发布，CI 会自动创建对应标签、Release、ZIP 和 `SHA256SUMS.txt`；以后发版只需递增 `VERSION`。

## 致谢与许可

- RMDTOC 读写核心基于 [Alan Wake 2 RMDTOC Tool](https://github.com/amrshaheen61/Alan-Wake-2-RMDTOC-Tool)，并加入 40 位/64 位 Blob 偏移修正。
- 本项目自身代码采用 [MIT License](LICENSE)。第三方说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

欢迎提交 Issue，但请不要上传、附带或请求分发游戏文件、翻译表和字体文件。

