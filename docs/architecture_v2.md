# Tile to Gridmap v2.0 — 架构设计文档

## 概述

本文档描述 Tile to Gridmap 插件从 v1.x 到 v2.0 的架构重设计方案。

**核心目标：** 去除 2D TileMapLayer 中间层，允许用户直接在 3D 视口中绘制地形，GridMap 实时更新。

**保留核心：** Dual-Grid 双网格位掩码算法不变，仅替换数据存储和输入方式。

---

## 与 v1.x 的对比

| 维度 | v1.x | v2.0 |
|------|------|-------|
| 绘制方式 | 2D TileMap 编辑器绘制，点击 Build 转换 | 直接在 3D 视口点击/拖拽绘制 |
| 数据存储 | TileMapLayer 节点（含 TileSet） | T2GLogicalGrid Resource（`.tres`） |
| 地形配置 | TileSet 自定义数据字段 | Painter 节点上的 Dictionary 属性 |
| 视觉反馈 | 无实时预览 | 3D 光标 + 即时 GridMap 更新 |
| 依赖 | TileSet + TileMapLayer | 仅 MeshLibrary |

---

## 系统架构总览

```
┌─────────────────────────────────────────────────────────┐
│  EditorPlugin (tile_to_gridmap.gd)                      │
│  ┌──────────────────┐   ┌────────────────────────────┐  │
│  │ _forward_3d_gui_ │   │  Dock UI                   │  │
│  │ input()          │   │  (tile_to_gridmap_ui.gd)   │  │
│  │                  │   │  - 地形调色盘               │  │
│  │ 事件分发中枢      │   │  - 工具模式切换             │  │
│  └────────┬─────────┘   │  - 高度控制                │  │
│           │             └────────────────────────────┘  │
└───────────┼─────────────────────────────────────────────┘
            │ 操作
            ▼
┌───────────────────────────┐
│  T2GGridmapPainter        │  extends Node3D, @tool
│  (t2g_gridmap_painter.gd) │
│                           │
│  @export grid_map         │──→ GridMap（MeshLibrary）
│  @export grid_height      │
│  @export logical_grid_data│──→ T2GLogicalGrid.tres
│  @export terrain_heights  │      { "grass":0, "dirt":1 }
│  @export terrain_excludes │      { "cliff":[0,1,2] }
│                           │
│  paint_cell()             │
│  erase_cell()             │
│  rebuild_cell()           │  ← 局部重建（最多20格）
│  rebuild_gridmap()        │  ← 全量重建
│  clear_gridmap()          │
└───────────────────────────┘
            │ 读写
            ▼
┌───────────────────────────┐
│  T2GLogicalGrid           │  extends Resource
│  (t2g_logical_grid.gd)    │
│                           │
│  get_cell(Vector2i)→String│
│  set_cell(Vector2i,String)│
│  erase_cell(Vector2i)     │
│  get_used_cells()→Array   │
│  clear()                  │
│                           │
│  内部：并行数组序列化       │
│  _keys_x: PackedInt32Array│
│  _keys_y: PackedInt32Array│
│  _values: PackedStringArray│
└───────────────────────────┘
```

---

## 模块详细设计

### 1. EditorPlugin — `tile_to_gridmap.gd`

**职责：** 插件生命周期、3D 视口输入拦截、节点选择感知、Undo/Redo。

#### 关键回调

```gdscript
# 当用户在场景树中选中 T2GGridmapPainter 节点时激活插件
func _handles(object: Object) -> bool:
    return object is T2GGridmapPainter

func _edit(object: Object) -> void:
    _active_painter = object as T2GGridmapPainter
    _cursor.attach_to(_active_painter)
    _ui.refresh_palette(_active_painter)
    make_bottom_panel_item_visible(_ui)  # 或 dock 显示

func _make_visible(visible: bool) -> void:
    _cursor.visible = visible
```

#### 输入处理结构（借鉴 TileMapLayer3D）

```gdscript
func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
    if not is_active or not _active_painter:
        return AFTER_GUI_INPUT_PASS

    # 缓存鼠标位置（用于键盘事件时的光标刷新）
    if event is InputEventMouse:
        _cached_mouse_pos = event.position

    # 鼠标移动：更新光标预览（带节流）
    if event is InputEventMouseMotion:
        _handle_mouse_motion(event, camera)
        return AFTER_GUI_INPUT_PASS  # 不消耗，允许摄像机旋转

    # 鼠标按键：绘制/擦除
    if event is InputEventMouseButton:
        return _handle_mouse_button(event, camera)

    # 键盘：高度切换等
    if event is InputEventKey and event.pressed:
        return _handle_key(event, camera)

    return AFTER_GUI_INPUT_PASS
```

#### 绘制节流策略（借鉴 TileMapLayer3D）

```gdscript
# 双重节流：时间阈值 + 位置阈值
const PAINT_INTERVAL_MS := 50.0          # 最快 20fps 更新
const PREVIEW_MOVE_THRESHOLD := 2.0     # 鼠标移动超过 2px 才刷新预览

var _last_paint_time: float = 0.0
var _last_preview_grid_pos: Vector2i = Vector2i(-99999, -99999)
```

#### Undo/Redo

```gdscript
# 鼠标按下时记录快照，松开时提交一次 action
var _undo_snapshot: Dictionary = {}  # Vector2i → String（旧值）

func _on_paint_begin():
    _undo_snapshot.clear()

func _on_paint_end():
    if _undo_snapshot.is_empty(): return
    var undo_redo = get_undo_redo()
    undo_redo.create_action("T2G Paint Terrain")
    undo_redo.add_do_method(_active_painter, "_apply_cell_batch", _new_cells)
    undo_redo.add_undo_method(_active_painter, "_apply_cell_batch", _undo_snapshot)
    undo_redo.commit_action()
```

---

### 2. 平面检测与射线投影

**设计决策：** 不采用 TileMapLayer3D 的 6 平面系统，仅支持 XZ 水平面（GridMap 本身是水平网格）。多高度通过 `grid_height` 控制，等同于切换不同 Y 值的水平面。

#### 射线→逻辑格子坐标

```gdscript
func _screen_to_logical_cell(camera: Camera3D, screen_pos: Vector2) -> Vector2i:
    var ray_origin := camera.project_ray_origin(screen_pos)
    var ray_dir    := camera.project_ray_normal(screen_pos)

    # 投影到 Y = grid_height * cell_size.y 平面
    var cell_size  := _active_painter.grid_map.cell_size
    var plane_y    := _active_painter.grid_height * cell_size.y
    var plane      := Plane(Vector3.UP, plane_y)

    var hit: Variant = plane.intersects_ray(ray_origin, ray_dir)
    if hit == null:
        return Vector2i(-99999, -99999)  # 未命中（摄像机平行于平面）

    # 转换到逻辑格子坐标（Dual-Grid：逻辑格子比 GridMap 格子偏移半格）
    var lx := floori(hit.x / cell_size.x)
    var ly := floori(hit.z / cell_size.z)
    return Vector2i(lx, ly)
```

**坐标关系说明：**

```
逻辑格子 (lx, ly) 对应 GridMap 中的 4 个格子：
  (lx,   height, ly  )   (lx+1, height, ly  )
  (lx,   height, ly+1)   (lx+1, height, ly+1)

这与 v1.x 中 NEIGHBOURS 数组定义完全一致，算法无需修改。
```

---

### 3. T2GGridmapPainter — `t2g_gridmap_painter.gd`

**职责：** 数据持有、位掩码计算、GridMap 写入。从 `T2GTerrainLayer` 演化而来，去除所有 TileMapLayer 依赖。

#### 节点定义

```gdscript
@tool
extends Node3D
class_name T2GGridmapPainter

@export var grid_map: GridMap
@export var grid_height: int = 0
@export var logical_grid_data: T2GLogicalGrid

# 地形高度优先级（替代 TileSet 自定义数据的 Height 字段）
# 示例: { "grass": 0, "dirt": 1, "water": 0, "cliff": 2 }
@export var terrain_heights: Dictionary = {}

# 排除特定 bitmask ID（替代 TileSet 自定义数据的 Exclude 字段）
# 示例: { "cliff": [0, 1, 2] }
@export var terrain_excludes: Dictionary = {}

# 工具按钮（保留，方便不用 UI 时手动操作）
@export_tool_button("Rebuild Gridmap") var _btn_rebuild = rebuild_gridmap
@export_tool_button("Clear Gridmap")   var _btn_clear   = clear_gridmap
```

#### 局部重建（性能关键）

每次绘制只重建受影响的 GridMap 格子，而非全量重建：

```gdscript
func rebuild_cell(logical_pos: Vector2i) -> void:
    # 一个逻辑格子的改变，最多影响以其为中心的 3x3 逻辑区域内的 GridMap 格子
    # 实际受影响的 GridMap 格子 = 以 logical_pos 为圆心，半径 1 的范围
    var affected := _get_affected_gridmap_cells(logical_pos)
    for gm_pos in affected:
        _recompute_gridmap_cell(gm_pos)

func _get_affected_gridmap_cells(logical_pos: Vector2i) -> Array[Vector3i]:
    # logical_pos 作为 Dual-Grid 中心，影响范围：
    # 自身产生的 4 个 GridMap 格子 + 周边 8 个逻辑格子各自的 4 个 GridMap 格子
    # 去重后最多 20 个 GridMap 格子
    var result: Array[Vector3i] = []
    for dx in range(-1, 3):
        for dz in range(-1, 3):
            var gm := Vector3i(
                logical_pos.x + dx,
                grid_height,
                logical_pos.y + dz
            )
            if gm not in result:
                result.append(gm)
    return result
```

#### 位掩码算法（与 v1.x 完全一致，仅数据源不同）

```gdscript
# v1.x：从 TileMapLayer 读
func match_tile_name(tile_data, tile_name: String) -> bool:
    if tile_data:
        return tile_data.get_custom_data("Name") == tile_name
    return false

# v2.0：从 T2GLogicalGrid 读
func match_tile_name(cell_pos: Vector2i, tile_name: String) -> bool:
    return logical_grid_data.get_cell(cell_pos) == tile_name
```

其余 `calculate_grid_tile()`、`pick_name_by_height()`、`pick_random_variant()`、`cache_tile_variants()` 逻辑**完全不变**。

---

### 4. T2GLogicalGrid — `resources/t2g_logical_grid.gd`

**职责：** 逻辑网格数据的序列化存储，替代 TileMapLayer 的 cell 存储。

#### 设计考量

Godot 4.4 中 `Dictionary[Vector2i, String]` 在 Resource 内可序列化，但为了跨版本兼容性，采用并行数组方案：

```gdscript
extends Resource
class_name T2GLogicalGrid

# 序列化存储（并行数组，安全跨 Godot 版本）
@export var _keys_x: PackedInt32Array = []
@export var _keys_y: PackedInt32Array = []
@export var _values: PackedStringArray = []

# 运行时缓存（不序列化）
var _cache: Dictionary = {}
var _cache_dirty: bool = true

func get_cell(pos: Vector2i) -> String:
    _rebuild_cache_if_needed()
    return _cache.get(pos, "")

func set_cell(pos: Vector2i, terrain: String) -> void:
    _rebuild_cache_if_needed()
    if _cache.get(pos, "") == terrain:
        return  # 无变化，跳过
    _cache[pos] = terrain
    _sync_cache_to_arrays()
    emit_changed()

func erase_cell(pos: Vector2i) -> void:
    _rebuild_cache_if_needed()
    if not _cache.has(pos):
        return
    _cache.erase(pos)
    _sync_cache_to_arrays()
    emit_changed()

func get_used_cells() -> Array[Vector2i]:
    _rebuild_cache_if_needed()
    return _cache.keys()

func clear() -> void:
    _cache.clear()
    _keys_x.clear()
    _keys_y.clear()
    _values.clear()
    emit_changed()

func _rebuild_cache_if_needed() -> void:
    if not _cache_dirty: return
    _cache.clear()
    for i in _keys_x.size():
        _cache[Vector2i(_keys_x[i], _keys_y[i])] = _values[i]
    _cache_dirty = false

func _sync_cache_to_arrays() -> void:
    _keys_x.clear(); _keys_y.clear(); _values.clear()
    for pos in _cache:
        _keys_x.append(pos.x)
        _keys_y.append(pos.y)
        _values.append(_cache[pos])
```

---

### 5. T2GCursor3D — `nodes/t2g_cursor_3d.gd`

**职责：** 在 3D 视口中显示当前鼠标悬停的逻辑格子位置。借鉴 `TileCursor3D` 思路，大幅简化。

#### 设计

```gdscript
@tool
extends Node3D
class_name T2GCursor3D

# 高亮方块：覆盖逻辑格子对应的 2x2 GridMap 格子区域
var _highlight_mesh: MeshInstance3D

# 颜色：绘制模式绿色，擦除模式红色
var _paint_color  := Color(0.2, 1.0, 0.3, 0.35)
var _erase_color  := Color(1.0, 0.2, 0.2, 0.35)

func move_to(logical_pos: Vector2i, cell_size: Vector3, height: int) -> void:
    # 逻辑格子 (lx,ly) → 世界坐标中心
    # Dual-Grid 特性：高亮区域覆盖 GridMap 的 (lx,h,ly)~(lx+1,h,ly+1)
    var world_x := (logical_pos.x + 0.5) * cell_size.x  # 2格宽的中心
    var world_y :=  height * cell_size.y + cell_size.y * 0.5
    var world_z := (logical_pos.y + 0.5) * cell_size.z
    position = Vector3(world_x, world_y, world_z)
    visible = true

func set_mode_paint() -> void:
    (_highlight_mesh.material_override as StandardMaterial3D).albedo_color = _paint_color

func set_mode_erase() -> void:
    (_highlight_mesh.material_override as StandardMaterial3D).albedo_color = _erase_color
```

**高亮 Mesh 尺寸：**
- X = `cell_size.x * 2`（覆盖 2 个 GridMap 格子）
- Y = `cell_size.y * 0.05`（薄片，不干扰视线）
- Z = `cell_size.z * 2`

---

### 6. Dock UI — `tile_to_gridmap_ui.gd`

#### UI 布局

```
┌─────────────────────────────┐
│  Tile to Gridmap  v2.0      │
├─────────────────────────────┤
│  节点: [T2GGridmapPainter]  │
│  高度:  ▼ 0  ▲    [SpinBox] │
├─────────────────────────────┤
│  工具:  [绘制] [擦除] [填充] │
├─────────────────────────────┤
│  地形                        │
│  ┌──────────────────────┐   │
│  │ [grass] [dirt] [sand]│   │  ← 从 MeshLibrary 自动生成
│  │ [water] [cliff] ...  │   │
│  └──────────────────────┘   │
├─────────────────────────────┤
│  [重建 Gridmap] [清空]       │
└─────────────────────────────┘
```

#### 地形调色盘自动生成

```gdscript
func refresh_palette(painter: T2GGridmapPainter) -> void:
    _clear_palette()
    if not painter?.grid_map?.mesh_library:
        return
    var lib := painter.grid_map.mesh_library
    var terrain_names := _extract_terrain_names(lib)
    for name in terrain_names:
        var btn := Button.new()
        btn.text = name
        btn.toggle_mode = true
        btn.button_group = _terrain_group
        # 用 item 15（完整块）的 mesh 生成缩略图
        var preview_mesh := _get_preview_mesh(lib, name)
        if preview_mesh:
            btn.icon = _make_mesh_preview(preview_mesh)
        btn.pressed.connect(func(): _selected_terrain = name)
        _palette_container.add_child(btn)

func _extract_terrain_names(lib: MeshLibrary) -> Array[String]:
    var names: Array[String] = []
    for id in lib.get_item_list():
        var raw := lib.get_item_name(id)
        # 去掉末尾小写字母（变体后缀），再去掉末尾数字（bitmask ID）
        var base := raw.rstrip("abcdefghijklmnopqrstuvwxyz").rstrip("0123456789")
        if base != "" and base not in names:
            names.append(base)
    return names
```

---

### 7. T2GProcGenManager（适配更新）

去除 TileSet/TileMapLayer 依赖，改为直接写入 `T2GLogicalGrid`。

#### 主要变化

| v1.x | v2.0 |
|------|------|
| `extends Node2D` | `extends Node3D` |
| `@export tileset: TileSet` | 删除 |
| `tilemap.set_cell(pos, 0, atlas_coords)` | `painter.logical_grid_data.set_cell(pos, terrain.name)` |
| chunk 分帧处理（防 2D 崩溃） | 简化，或保留用于超大地图 |
| `apply_transitions()`（2D 过渡块） | 删除 |
| 生成后调用各 chunk `build_gridmap()` | 调用 `painter.rebuild_gridmap()` 一次 |

#### `T2GTerrain` Resource 简化

```gdscript
# v1.x（删除 TileSet 相关字段）
extends Resource
class_name T2GTerrain

@export var name: String
@export_range(0, 1) var noise_min: float
@export_range(0, 1) var noise_max: float
@export var height: int = 0          # 新增，用于 terrain_heights 配置
# 删除：atlas_coordinates, transition_tile_outer, transition_tile_inner
```

---

## 文件变动清单

### 新建

| 文件 | 说明 |
|------|------|
| `resources/t2g_logical_grid.gd` | 逻辑网格 Resource |
| `nodes/t2g_cursor_3d.gd` | 3D 光标节点 |
| `t2g_gridmap_painter.gd` | 核心 Painter 节点（替代 terrain_layer） |

### 重写

| 文件 | 变化说明 |
|------|---------|
| `tile_to_gridmap.gd` | 添加 3D 视口输入、节点选择感知、Undo/Redo |
| `tile_to_gridmap_ui.gd` | 地形调色盘、工具模式、高度控制 |
| `tile_to_gridmap_ui.tscn` | 对应新 UI 布局 |
| `t2g_proc_gen_manager.gd` | 去除 TileSet，写入 LogicalGrid |
| `resources/t2g_terrain.gd` | 删除 atlas 字段，加 height |

### 删除

| 文件 | 原因 |
|------|------|
| `t2g_terrain_layer.gd` | 被 `t2g_gridmap_painter.gd` 替代 |

### 不变

| 文件 | 原因 |
|------|------|
| `t2g_props.gd` | 纯 3D GridMap 操作，无 2D 依赖 |
| `resources/t2g_prop.gd` | 数据结构不变 |
| `resources/t2g_biome.gd` | 空 stub，保留 |

---

## 实现阶段规划

### Phase 1 — 数据层（无 UI，无交互）
1. 实现 `T2GLogicalGrid` Resource
2. 实现 `T2GGridmapPainter`，移植位掩码算法
3. 通过 Inspector 的 `@export_tool_button` 手动验证 rebuild 结果与 v1.x 一致

### Phase 2 — 3D 视口交互
4. 实现 `T2GCursor3D` 高亮节点
5. 在 `tile_to_gridmap.gd` 中实现 `_forward_3d_gui_input`：射线投影、paint/erase
6. 实现绘制节流（双重阈值）

### Phase 3 — UI
7. 重写 Dock UI：地形调色盘、工具模式、高度 SpinBox
8. 接入 MeshLibrary 自动提取地形名 + 缩略图

### Phase 4 — Undo/Redo + ProcGen
9. 实现基于 `EditorUndoRedoManager` 的 Undo/Redo
10. 更新 `T2GProcGenManager`

### Phase 5 — 清理
11. 删除 `t2g_terrain_layer.gd` 及所有 TileSet 相关引用
12. 更新 `plugin.cfg` 版本号
13. 更新 README

---

## 关键设计决策记录

### 为何不用 TileMapLayer3D 的 6 平面系统？
GridMap 是水平网格，Dual-Grid 算法基于 XZ 平面的 2D 逻辑坐标。引入墙面/天花板绘制会破坏双网格的邻居计算逻辑，且无实际需求。多高度用 `grid_height` 解决。

### 为何用并行数组而非 Dictionary 序列化 T2GLogicalGrid？
Dictionary 在不同 Godot 版本中的序列化行为存在差异，并行 PackedArray 是 Godot Resource 序列化的最安全形式，并有更好的内存局部性。

### 为何局部重建而非全量重建？
全量重建在大地图（1000+ 逻辑格子）时每次笔触都要遍历所有格子，卡顿明显。局部重建每次最多更新 20 个 GridMap 格子，体验与笔触大小无关。

### Undo/Redo 为何按笔触而非按格子提交？
按格子提交会导致 Ctrl+Z 一次只撤销一个格子，拖拽绘制 50 个格子需要按 50 次 Undo，体验极差。按鼠标按下→松开作为一次 action，一次 Undo 撤销整个笔触。
