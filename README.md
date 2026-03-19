# Bird Companion — Godot 项目说明文档

## 项目背景

这是一个桌面宠物应用，由两个部分组成：
1. **这个 Godot 项目（bird-companion）**：负责渲染带骨骼动画的小鸟，以透明背景常驻在用户桌面上
2. **原 Electron 项目（desktopCompanion）**：负责连接 OpenClaw AI 助手的 WebSocket，接收工作状态

**最终目标**：把 OpenClaw 的 WebSocket 连接也迁移到 Godot，彻底替代 Electron，成为单一可执行文件（.exe）的桌面宠物。

---

## Godot 场景结构（node_2d_bird.tscn）

```
Node2D                       ← 根节点，挂载主脚本 bird.gd
├── stick                    ← 树枝（Polygon2D，静态贴图）
├── body                     ← 鸟身体（Polygon2D，已绑骨骼 hip/chest）
│   ├── claw                 ← 爪子（Polygon2D，静态）
│   ├── leftwing             ← 左翅膀（Polygon2D，默认隐藏，已绑骨骼）
│   ├── rightwing            ← 右翅膀（Polygon2D，默认隐藏，已绑骨骼）
│   ├── head                 ← 头部（Polygon2D，已绑骨骼 hip/chest/head）
│   └── face                 ← 脸（Polygon2D，随头骨骼）
├── Skeleton2D               ← 骨骼根节点
│   └── hip                  ← 骨骼：髋部
│       └── chest            ← 骨骼：胸部
│           ├── head         ← 骨骼：头
│           ├── leftwing     ← 骨骼：左翅
│           └── rightwing    ← 骨骼：右翅
├── AnimationPlayer          ← 播放器，储存所有动画关键帧
│   ├── RESET                ← 默认姿势（自动生成）
│   ├── idle                 ← 呼吸动画（循环，3.1秒，hip scale 呼吸起伏）
│   └── tiltinghead          ← 歪头动画（循环，head position/rotation 变化）
└── AnimationTree            ← 状态机控制器，挂载 bird.gd 里的逻辑
```

### AnimationTree 状态机结构

```
[Start] → [idle] ←→ [tiltinghead]
```

- **Start → idle**：自动进入（advance_mode = Auto）
- **idle → tiltinghead**：条件 `do_tilting = true`，Switch Mode = At End（播完 idle 当前循环才切）
- **tiltinghead → idle**：自动返回（advance_mode = Auto，switch_mode = At End，播完一次自动回）

条件变量路径：`parameters/conditions/do_tilting`

---

## 已完成的工作

- [x] 从 PS 分层导入 PSD 素材（bird-godot.png 精灵图）
- [x] 建立 Skeleton2D 骨骼结构（hip → chest → head/leftwing/rightwing）
- [x] 为 body, head, face, leftwing 绑定骨骼权重
- [x] 制作 `idle` 动画（呼吸起伏，3.1 秒循环）
- [x] 制作 `tiltinghead` 动画（头部歪头，0.8 秒循环）
- [x] 建立 AnimationTree 状态机，连接 idle ↔ tiltinghead
- [x] 配置 `do_tilting` 条件变量

## 待完成的工作

- [ ] 在 Node2D 上挂载 `bird.gd` 脚本（见下方代码）
- [ ] 设置透明背景窗口（项目设置）
- [ ] 连接 OpenClaw WebSocket（替代 Electron）
- [ ] 制作更多动画（working, done, spreadwings 等）
- [ ] 配件系统（帽子等挂载到 head 骨骼子节点）

---

## 项目设置（透明窗口）

**项目 → 项目设置 → 显示 → 窗口**（需开启"高级设置"）：

| 设置 | 值 |
|------|-----|
| 每像素透明度（Per Pixel Transparency） | ✅ 启用 |
| 无边框（Borderless） | ✅ 启用 |

**项目 → 项目设置 → 渲染 → 视口**：

| 设置 | 值 |
|------|-----|
| 透明背景（Transparent Background） | ✅ 启用 |

---

## 主脚本（bird.gd）

将脚本文件创建于 `res://bird.gd`，然后在 Godot 编辑器里把它拖到 Node2D 节点上。

脚本内容见 `bird.gd` 文件，主要功能：
- 启动时让 AnimationTree 开始运行
- 定时/随机触发 `do_tilting` 条件，让小鸟随机歪头
- 连接 OpenClaw WebSocket，根据 AI 工作状态切换动画

---

## OpenClaw WebSocket 认证协议

**地址**：`wss://[你的 Cloudflare Tunnel 域名]`（或直接用内网 IP）

**认证流程**：
1. 建立连接
2. 服务器发送 `connect.challenge`
3. 客户端回复：
```json
{
  "type": "req",
  "id": "<uuid>",
  "method": "connect",
  "params": {
	"minProtocol": 3,
	"maxProtocol": 3,
	"client": { "id": "cli", "version": "2026.3.2", "platform": "windows", "mode": "cli" },
	"role": "operator",
	"scopes": ["operator.read", "operator.write"],
	"auth": { "token": "lobster123" }
  }
}
```
4. 服务器返回 `type: "res"` 且 `ok: true` → 认证成功

**关键事件**：
- `agent phase: start` → 切换到 `working` 状态
- `agent phase: end` → 切换到 `done` 状态，3 秒后回 `idle`
