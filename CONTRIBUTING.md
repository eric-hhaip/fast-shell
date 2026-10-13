# 贡献指南

感谢你愿意为 Fast Shell 出力。本文档说明如何搭建环境、代码约定与提交流程。

## 目录

- [开发环境](#开发环境)
- [常用命令](#常用命令)
- [代码约定](#代码约定)
- [提交规范](#提交规范)
- [Pull Request 流程](#pull-request-流程)

---

## 开发环境

| 项 | 要求 |
| --- | --- |
| 系统 | macOS 12+（Apple Silicon / Intel） |
| Flutter | 3.47+（Dart SDK `^3.13.5`） |
| Xcode | Command Line Tools 已安装 |

```bash
git clone https://cnb.cool/hhaip.com/opensource/fast-shell.git
cd fast-shell
flutter pub get
flutter run -d macos
```

## 常用命令

```bash
flutter run -d macos          # 开发运行（热重载）
dart run tool/verify.dart     # 纯 Dart 自检（119 项，不需要 GUI）
flutter analyze               # 静态检查
flutter test                  # Widget 测试（部分沙盒环境可能起不了 flutter_tester）
tool/build_release.sh         # 发布打包：剥符号 + 产物体检
```

> `tool/verify.dart` 不依赖 `dart:ui`，因此在任何能跑 Dart 的环境（含 CI 容器）都能执行，
> 是最快的回归手段。新增纯逻辑（解析、文本处理、路径规则等）时，请顺手补上用例。

## 代码约定

- **依赖注入**：全局状态用 `provider`，从 `AppStore` 读取；不要在 Widget 里直接 new 服务
- **异步必须兜错**：所有用户可触发的异步动作都要 `try/catch` 并把错误通过 snackbar / 内联提示暴露出来。
  吞异常会导致「点了没反应」，这是本项目明确要避免的问题
- **纯逻辑抽离**：凡是可以在无 UI 环境下测试的逻辑，放到 `lib/services/` 并保持无 Flutter 依赖
- **本地落盘**：统一走 `LocalIo`，不要直接拼路径。
  用户自选目录必须先 `probeWritable()` 探测，失败回退 `~/Downloads`
- **原子写文件**：下载 / 上传一律「临时文件 + 原子改名」，中途失败不得留下半截文件
- **重绘隔离**：新增会频繁刷新的可视区域，请包 `RepaintBoundary`，
  `CustomPainter` 必须正确实现 `shouldRepaint`
- **终端输出**：不得截断用户日志。渲染性能问题靠渲染方案解决，不靠丢数据解决
- **换行**：写入终端换行统一用 `\r\n`（只写 `\n` 不会回到列首，会出现阶梯状缩进）
- **不要剔除 ESC（0x1B）**：它是 ANSI 颜色 / 光标控制的引导字节，净化日志时只清 `NUL`

## 提交规范

提交信息使用 `type(scope): subject` 形式，type 取值：

| type | 含义 |
| --- | --- |
| `feat` | 新功能 |
| `fix` | 缺陷修复 |
| `perf` | 性能优化 |
| `refactor` | 重构（不改变外部行为） |
| `docs` | 文档 |
| `build` | 构建 / 依赖 / 打包 |
| `test` | 测试 |
| `chore` | 杂项 |

示例：

```
feat(monitor): 新增容器日志全屏查看
perf(terminal): 终端改用字符网格渲染，消除长日志花屏
fix(sftp): 修复取消下载后残留半截文件
```

## Pull Request 流程

1. 从 `main` 切出分支：`git checkout -b feat/your-feature`
2. 完成改动，本地跑通：
   ```bash
   dart run tool/verify.dart
   flutter analyze
   ```
3. 提交前自检清单：
   - [ ] 新增纯逻辑已补 `tool/verify.dart` 用例
   - [ ] `flutter analyze` 无 warning 及以上
   - [ ] 涉及 UI 的改动已在 macOS 上实际点过一遍
   - [ ] 涉及 entitlements 的改动已在 PR 描述里说明原因（本项目刻意不用 App Sandbox，见 `Release.entitlements` 注释）
   - [ ] 更新了 `CHANGELOG.md`
4. 提交 PR，描述里写明：**改了什么 / 为什么改 / 怎么验证**
5. 若改动涉及渲染或大量文件，请附上前后对比（截图或数据）

## 报告问题

提 Issue 时请尽量带上：

- macOS 版本与芯片（Apple Silicon / Intel）
- 应用版本（设置页可见）
- 复现步骤与预期 / 实际表现
- 相关截图或日志片段（截图请包含完整界面，便于判断是否为渲染问题）

> 注意：请勿在 Issue 中粘贴真实的主机地址、账号、私钥或密码。日志里的敏感信息请先打码。
