# Cookie 的小日子 🍪

Cookie 从 Cookieland 插画里走到 Mac 桌面，变成一个会散步、会搞怪，也会陪你整理零散想法的小伙伴。

![Cookieland 原创角色 Cookie](assets/cookie.png)

## 试一试

打开仓库根目录的 `index.html`，可体验一个静态交互预览：拖动 Cookie、点击打开计划、调整大小和速度、打勾，以及看它戴耳机。网页中的任务、聊天回复和音乐状态都是**演示数据**；真实 Codex 对话与本机 Spotify 控制在 macOS App 中。

录屏顺序见 [DEMO.md](DEMO.md)。

## macOS App

- Cookie 在桌面上连续迈步；按住拖动可换位置，单击弹出计划和聊天窗口。
- 在「今天」里设置 60%–160% 大小和散步速度；完成事项可以打勾，也可为未完成事项保存工作链接。
- 随便把想做的事说给 Cookie，它会区分本周任务、以后任务和纯灵感，按你说的优先级同步「今天」与「本周」。需要你做取舍时，它会给出可点选的答案。
- 「本周」按优先级显示进展；纯灵感有独立的「灵感」页。今天只放一件主线和至多一件可选小事，未完成不用补作业。
- 播放本机 Spotify 时，Cookie 会戴耳机；暂停后恢复普通状态。
- 个人计划保存在 App 同目录的 `cookie-companion-state.json`，已被 Git 忽略。仓库只有虚构示例，不包含使用者的对话或计划。

在 macOS 26 或更新系统上安装 Xcode Command Line Tools 后，运行：

```zsh
zsh app/build.sh
open "dist/Cookie 的小日子.app"
```

对话需要本机 ChatGPT 桌面版所附的 Codex CLI。语音输入需要麦克风和语音识别权限；Spotify 控制为可选功能，首次使用可能需要 macOS 自动化权限。

「学习」页使用个人课表时，把 `daily-learning-plan.json` 放在 App 同目录的 `learning-plan` 文件夹；也可以在 App 同目录的 `cookie-learning-source.txt` 写入已有课表文件夹的绝对路径。课表和该路径文件只留在本机，不放进公开仓库。

## Skill

[`skills/cookieland-desk-buddy/SKILL.md`](skills/cookieland-desk-buddy/SKILL.md) 记录这个桌宠已确定的角色比例、动作节奏和轻量计划原则，供下一次迭代继续使用。它不会自动发布内容或上传个人数据。

Cookie / Cookieland 角色与插画 © CookieBlukie。代码与原创画作尚未开放再授权；请勿把它们当作可自由商用素材。`Xiaolai-Regular.ttf` 随附其 [OFL 授权说明](assets/Xiaolai-OFL.txt)。
