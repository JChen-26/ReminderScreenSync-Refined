# AI便利贴提醒事项同步

> ⚠️ ** vibe coding 作品，请谨慎使用 **
>
> 本人完全不会写代码，也看不懂代码。这个项目是全程用 AI（vibe coding）糊出来的，git 也是现学现卖的，一切操作都不规范。
>
> **Co-author: Kimi Code / CLI**
>
> 所以：代码很乱？正常。有 bug？太正常了。看不懂我在干嘛？我也看不懂。
>
> 🙏 **致谢与说明**
>
> 本项目 fork 自 [github.com/justinfjx/ReminderScreenSync](https://github.com/justinfjx/ReminderScreenSync)，原作者搭建了非常棒的底子。我在此基础上用 AI 瞎改了一堆功能，如果改得不好、代码风格奇怪、或者哪里冒犯了原作者的品味……请多多谅解！一切问题都是我的锅，与原项目无关。
>
> 一切请自取自用，随心折腾，**后果自负**。

---

`AI便利贴提醒事项同步` 是一个 macOS 原生应用，用于在 Apple Reminders 与 Zectrix `AI便利贴` 设备之间执行双向同步。应用支持多列表合并、多设备映射、菜单栏常驻、开机自启动、轮询周期配置、同步日志审计，以及基于"最新修改时间"的冲突处理。

## 重要提示

- 当前版本仍处于早期阶段，请务必先在测试列表或可接受风险的环境中使用。
- 本软件会读取、创建、修改，且在特定同步规则下删除 Apple Reminders 中的内容。
- 在正式投入使用前，请先充分测试同步、删除、重复标题、重复规则、逾期项目等场景。
- 如果你对现有提醒事项数据较为敏感，建议先备份，再启用同步。

## 项目定位

本项目面向 `AI便利贴` 设备与 Apple Reminders 的双向同步场景。软件依赖极趣云平台接口与 Apple EventKit，不对设备硬件规格做额外假设，也不要求用户关注底层参数。

## 主要能力

- 多个 Apple Reminders 列表勾选后合并同步到同一台 AI便利贴设备
- **多设备多列表映射**：支持创建多个独立同步任务，每个任务对应不同设备和列表组合
- **菜单栏常驻模式**：关闭主窗口后仍通过菜单栏运行，支持快速查看状态和一键同步
- **开机自启动 + 自动恢复**：登录时自动启动应用，并自动恢复上次运行的同步任务
- Apple Reminders 变更监听 + 设备端定时轮询
- 标题唯一时自动配对；标题重复时采用保守策略，跳过自动配对和自动删除
- 待办标题、备注、日期、时间、优先级、完成状态双向同步
- 支持基础重复规则同步：`daily / weekly / monthly / yearly`
- 对逾期待办、已完成待办、设备删除、设备 `id` 复用等场景提供保护逻辑
- 本地运行日志，便于排查同步行为（带任务名称前缀）

## 同步规则摘要

1. 选中的 Reminders 列表会先合并，再与设备待办进行比对。
2. 标题一致时，优先视为同一条待办；若存在历史同步记录，则优先使用历史映射。
3. Apple Reminders 中已完成且设备中不存在的项目，不会重新创建到设备。
4. 设备中删除未完成待办时，会删除来源列表中的对应提醒事项；设备中删除已完成待办时，不删除提醒事项。
5. Apple Reminders 中已逾期但未完成的项目，不会因为设备侧不存在而被误删。
6. 设备 `id` 被删除后复用时，只有在 `createDate` 能证明是同一条记录时才继续沿用。
7. 复杂重复规则不会被错误降级写入设备；设备 API 不支持的规则会保守跳过。

## 已知限制

- 当前设备开放接口只支持基础重复类型，不支持 Apple Reminders 中更复杂的重复表达方式，例如"每 2 周"或"多个工作日"。
- Apple Reminders 侧若存在重复标题，系统会跳过这些标题的自动配对与自动删除，以降低误操作风险。
- 设备侧若存在"重复规则但没有截止日期"的待办，Apple Reminders 不允许将其保存为重复提醒，因此系统只会保留普通待办信息，不会写入重复规则。

## 运行要求

- macOS 13.0 或更高版本
- Xcode 15 或更高版本
- 可访问 Apple Reminders 的系统权限
- 极趣云平台 API Key
- 至少一台已绑定到账号的 AI便利贴设备

## 本地开发

打开工程：

```bash
open ReminderScreenSync.xcodeproj
```

命令行构建：

```bash
xcodebuild -project ReminderScreenSync.xcodeproj \
  -scheme ReminderScreenSync \
  -configuration Debug \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build
```

## 项目结构

```text
ReminderScreenSync/
├── AppModel.swift          # UI 状态与多 Profile 同步服务生命周期
├── ContentView.swift       # SwiftUI 主界面（Profile 列表 + 全局操作）
├── ProfileEditView.swift   # 同步任务编辑 Sheet
├── ProfileManager.swift    # 多同步任务 CRUD 与旧配置迁移
├── MenuBarView.swift       # 菜单栏常驻弹出面版
├── LaunchService.swift     # 开机自启动（SMAppService）封装
├── ReminderStore.swift     # Apple Reminders / EventKit 访问层
├── ZectrixAPIClient.swift  # 极趣云平台 API 客户端
├── SyncEngine.swift        # 双向同步核心逻辑
├── SyncRecordStore.swift   # 本地同步映射持久化
└── Models.swift            # 数据模型与同步辅助结构
```

## 使用流程

1. 打开应用，在「准备工作」面板中**授权 Apple Reminders**并填写极趣云平台 API Key。
2. 点击「加载设备」获取账号下的 AI便利贴 设备列表。
3. 点击「添加任务」，在弹出的编辑窗口中选择目标设备、Reminders 列表和轮询周期。
4. 点击任务卡片上的「启动」开始同步；也可使用「全部启动」一次性启动所有任务。
5. （可选）勾选「登录时自动启动」，下次开机将自动恢复同步。
6. 关闭主窗口后，应用仍通过**菜单栏图标**保持运行，可随时一键同步或退出。

## 隐私与数据

- API Key 保存在当前 macOS 用户的本地 `UserDefaults` 中。
- 同步映射与运行日志保存在本地，不上传到第三方服务。
- Apple Reminders 的访问仅用于读取、创建、更新、删除你在应用中勾选的列表内容。

## 许可

本仓库使用 `PolyForm Noncommercial 1.0.0`。

- 允许个人学习、研究、测试、非商业使用与非商业分发
- 不允许未经额外授权的商业使用

详细条款见 [LICENSE](./LICENSE) 与官方条款页面：

- [PolyForm Noncommercial 1.0.0](https://polyformproject.org/licenses/noncommercial/1.0.0/)

## 社区

如果这个项目对你有帮助，欢迎点一个 Star。

也欢迎通过 Issue 提交问题、需求和复现步骤，或通过 Pull Request 直接改进代码与文档。
