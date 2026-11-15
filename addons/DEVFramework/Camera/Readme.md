# Camera 机位模块

场景里放多个 `VirtualCamera3D`（只描述取景），唯一的真实 `Camera3D` 挂 `CameraBrain3D`；Brain 每帧挑出生效机位、混合姿态后写入相机。

## 怎么用

```gdscript
vcam.set_active(true)      # 参与竞争（参与 != 生效）
vcam.activate(0.5)         # 切换，本次过渡 0.5 秒
vcam.deactivate()          # 退出竞争，自动回落到上一个激活机位
CameraTool.activate(vcam, 0.5)   # 等价静态入口
```

竞争规则：`priority` 大者胜；同级取**最后激活者**。

| 对象 | 关键成员 |
|---|---|
| `VirtualCamera3D` | `active` / `priority` / `blend_time`（`<0` 用 Brain 默认）/ `blend_trans` `blend_ease`（默认 CUBIC、IN_OUT）/ `blend_style`（`CameraTool.BlendStyle`，默认 `SPHERICAL`）/ `lens_fov`（`>0` 覆盖 Brain fov）/ `target` / `behaviors` / `standby_update` |
| 静态 | `VirtualCamera3D.current`、`VirtualCamera3D.active_cameras` |
| 方法 | `set_active` / `activate(blend)` / `deactivate` / `get_pose()` / `snap_pose()` / `add_behavior()` / `clear_behaviors()` |
| 信号 | `active_changed(value)`、`current_changed(value)` |
| 行为资源 | `FollowBehaviorDef`（`offset` / 按轴 `damping` / `dead_zone` / `soft_zone`）、`LookAtBehaviorDef`、`NoiseBehaviorDef` |
| `CameraBrain3D` | `default_blend_time` / `blends` / `tracking_damping` / `ignore_time_scale` / `snap_on_ready` / `blend_pivot` / `position_offset` / `rotation_offset`；`snap_to_current()` / `refresh()` / `is_blending()` / `get_current_camera()` / `update_camera(delta)`；信号 `blend_started` / `blend_finished` |
| `CameraTool` | `get_brain()` / `get_camera()` / `get_current()` / `activate()` / `deactivate()` / `find(level,&"Name")` / `snap()` / `interpolate_transform()` / `impulse(pos,strength)` / `shake(strength)` / `clear_impulses()` |

## 坑

1. 不要写 `vcam.behaviors = [res]`：数组字面量被推断为无类型 `Array`，赋给类型化属性报 `Invalid assignment`。用 `add_behavior()` 或 `behaviors.append()`。
2. 抖动 / 鼠标跟随 / 震屏一律写 Brain 的 `position_offset` / `rotation_offset`；直接写相机 `position` / `rotation` 会被机位混合覆盖。两个 damping 别混：Brain `tracking_damping` 是相机追机位，`FollowBehaviorDef.damping` 是机位追目标。
3. 机位不要挂成 Brain 的子节点（反馈循环）；`look_at_*` 时不要挂在带缩放的父节点下。没有任何机位激活时 Brain 不接管相机。自定义行为资源必须无运行时状态（多机位共享）。
