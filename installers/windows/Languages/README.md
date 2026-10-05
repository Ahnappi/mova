# Windows 安装程序的中文语言文件

`ChineseSimplified.isl` 是 **Inno Setup 官方**的简体中文语言文件，
随仓库保存，编译时不依赖 CI 机器上装没装中文语言包（中文不是默认语言，
精简安装里可能根本没有 `Languages\ChineseSimplified.isl`）。

## 来源

- 上游：`jrsoftware/issrc` 仓库的 `Files/Languages/ChineseSimplified.isl`
- 文件头写着它对应的 Inno Setup 版本（当前是 `6.5.0+`）
- 大小 21516 字节，UTF-8（无 BOM），CRLF 换行
- SHA-256：`e0b0b350e2245f3c5e65586dfe43d574f6e7f06f2261149aba284954b3fc9a8d`

升级 Inno Setup 之后想同步新版翻译，重新下载同名文件覆盖即可：

```bash
curl -L -o installers/windows/Languages/ChineseSimplified.isl \
  https://cdn.jsdelivr.net/gh/jrsoftware/issrc@main/Files/Languages/ChineseSimplified.isl
```

**要存原始文件，不要存网页**：把 GitHub 的 HTML 页面存成 `.isl` 也能“看起来存在”，
但编译时报的错完全看不懂。`test/installer_language_test.dart` 会挡住这种情况。

英文仍然用编译器自带的 `compiler:Default.isl`（一定有），不复制进仓库。
