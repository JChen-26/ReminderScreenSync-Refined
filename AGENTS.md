# ReminderScreenSync 开发规范

## 协作流程

1. **头脑风暴** — 用户描述需求/想法
2. **Plan 模式** — 我进入 plan 模式，写详细实现计划到 `plans/`
3. **用户确认** — 用户 review 并确认 plan
4. **编码实现** — 我写代码，做最小化改动
5. **用户手动验证** — 用户在 Xcode 中 build 验证
6. **Build Release** — 验证通过后，build archive + DMG
7. **文档 & Release** — 更新版本号、README、git commit、GitHub Release + DMG 上传

## 构建规范

### Debug 验证
```bash
xcodebuild -project ReminderScreenSync.xcodeproj \
  -scheme ReminderScreenSync \
  -destination 'platform=macOS' \
  build
```

### Release Archive（忽略签名 + entitlements）
```bash
xcodebuild archive \
  -project ReminderScreenSync.xcodeproj \
  -scheme ReminderScreenSync \
  -configuration Release \
  -archivePath build/ReminderScreenSync.xcarchive \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_ENTITLEMENTS=ReminderScreenSync/ReminderScreenSync.entitlements
```

### DMG 打包
```bash
# 从 xcarchive 复制 app，ad-hoc 签名并嵌入 entitlements，打包 DMG
codesign --sign - --force --deep \
  --entitlements ReminderScreenSync/ReminderScreenSync.entitlements \
  path/to/ReminderScreenSync.app

hdiutil create -volname "ReminderScreenSync X.X" \
  -srcfolder path/to/app_and_Applications_alias \
  -ov -format UDZO \
  build/ReminderScreenSync-X.X.dmg
```

## 版本管理

- **版本号**：`Info.plist` 中更新 `CFBundleShortVersionString`（如 1.0 → 1.1）和 `CFBundleVersion`（如 1 → 2）
- **Git 作者**：`Jiaju Chen <andybenchen2002@gmail.com>`
- **Changelog**：在 `README.md` 末尾的 `## 更新日志` 章节添加
- **Release**：通过 GitHub Release 发布，DMG 作为附件上传

## 编码风格

- Swift：跟随现有代码风格，最小化改动
- 使用 `@MainActor` 标注 UI 相关类
- UserDefaults key 前缀：`ReminderScreenSync.`
- 新增功能先写 plan 到 `plans/` 目录
