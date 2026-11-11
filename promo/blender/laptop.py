"""Render the promo's hero shot: a generic aluminium laptop opening, with the Gistsmith home screen on its display.

Run headless (Blender 5.x), normally through render.sh:
  blender --background --factory-startup --python-exit-code 1 --python promo/blender/laptop.py -- \
    <screen-image> <out-dir> <frames> [<f1,f2,…>]

Writes `<out-dir>/####.webp` (RGBA, transparent background, 1920x1080) for frames 1..<frames>. The model is built from
primitives here, so no third-party model or Apple asset is involved. Every value is keyed to the frame number, so the
sequence is deterministic and the Remotion scene can play it frame for frame.
"""

import math
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import TypeVar

import bpy
from mathutils import Vector

T = TypeVar("T")

WIDTH = 1920
HEIGHT = 1080

BASE = Vector((0.304, 0.212, 0.011))
LID_THICKNESS = 0.006
SCREEN_ASPECT = 2400 / 1560
# <screen-image> <out-dir> <frames>; an optional fourth argument lists preview frames.
REQUIRED_ARGS = 3


@dataclass(frozen=True)
class RenderArgs:
    screen_image: Path
    out_dir: Path
    frames: int
    # Preview mode: render only these frames (empty = the whole sequence).
    only: tuple[int, ...]


def parse_args(argv: list[str]) -> RenderArgs:
    if "--" not in argv:
        raise SystemExit("Usage: blender --background --python laptop.py -- <screen-image> <out-dir> <frames>")
    rest = argv[argv.index("--") + 1 :]
    screen, out, frames = rest[:REQUIRED_ARGS]
    only = tuple(int(value) for value in rest[REQUIRED_ARGS].split(",")) if len(rest) > REQUIRED_ARGS else ()
    return RenderArgs(screen_image=Path(screen).resolve(), out_dir=Path(out).resolve(), frames=int(frames), only=only)


class BlenderTypeError(TypeError):
    """Raised when the Blender API hands back a different kind of datablock, node or socket than this script builds."""


def expect(value: object, kind: type[T], what: str) -> T:
    """Narrows a loosely typed Blender API result (sockets, modifiers, object data) to the class this script expects."""
    if not isinstance(value, kind):
        raise BlenderTypeError(f"Expected {what} to be {kind.__name__}, got {type(value).__name__}")
    return value


def node_tree(tree: bpy.types.ShaderNodeTree | None, owner: str) -> bpy.types.ShaderNodeTree:
    if tree is None:
        raise BlenderTypeError(f"{owner} has no node tree although use_nodes is set")
    return tree


def set_color(node: bpy.types.Node, socket: str, rgba: tuple[float, float, float, float]) -> None:
    expect(node.inputs[socket], bpy.types.NodeSocketColor, f"{node.name}.{socket}").default_value.foreach_set(rgba)


def set_float(node: bpy.types.Node, socket: str, value: float) -> None:
    target = node.inputs[socket]
    if isinstance(target, bpy.types.NodeSocketFloat | bpy.types.NodeSocketFloatFactor):
        target.default_value = value
    else:
        raise BlenderTypeError(f"Expected {node.name}.{socket} to be a float socket, got {type(target).__name__}")


def link(
    tree: bpy.types.ShaderNodeTree, source: bpy.types.Node, output: str, target: bpy.types.Node, socket: str
) -> None:
    # Typed as plain Node: the stubs declare some node subclasses' sockets as optional, which Blender never returns.
    _ = tree.links.new(source.outputs[output], target.inputs[socket])


def active_object(operation: str) -> bpy.types.Object:
    obj = bpy.context.active_object
    if obj is None:
        raise BlenderTypeError(f"{operation} left no active object")
    return obj


def material(name: str, color: tuple[float, float, float], metallic: float, roughness: float) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = node_tree(mat.node_tree, name).nodes["Principled BSDF"]
    set_color(bsdf, "Base Color", (*color, 1.0))
    set_float(bsdf, "Metallic", metallic)
    set_float(bsdf, "Roughness", roughness)
    return mat


def screen_material(image_path: Path) -> bpy.types.Material:
    """An emissive screenshot under a faint gloss, so the display shows true colours and still catches a highlight."""
    mat = bpy.data.materials.new("Screen")
    mat.use_nodes = True
    tree = node_tree(mat.node_tree, "Screen")
    bsdf = tree.nodes["Principled BSDF"]
    texture = expect(tree.nodes.new("ShaderNodeTexImage"), bpy.types.ShaderNodeTexImage, "screen texture node")
    texture.image = bpy.data.images.load(str(image_path))
    texture.interpolation = "Cubic"
    # Black base + emission 1.0 under the Standard view transform shows the screenshot's own sRGB colours.
    set_color(bsdf, "Base Color", (0, 0, 0, 1))
    link(tree, texture, "Color", bsdf, "Emission Color")
    set_float(bsdf, "Emission Strength", 1.0)
    set_float(bsdf, "Roughness", 0.12)
    set_float(bsdf, "Specular IOR Level", 0.12)
    return mat


def rounded_box(name: str, size: Vector, bevel: float, mat: bpy.types.Material) -> bpy.types.Object:
    _ = bpy.ops.mesh.primitive_cube_add(size=1)
    obj = active_object("primitive_cube_add")
    obj.name = name
    obj.scale = size
    _ = bpy.ops.object.transform_apply(scale=True)
    modifier = expect(obj.modifiers.new("Bevel", "BEVEL"), bpy.types.BevelModifier, f"{name} bevel")
    modifier.width = bevel
    modifier.segments = 8
    modifier.limit_method = "NONE"
    _ = bpy.ops.object.shade_smooth()
    expect(obj.data, bpy.types.Mesh, f"{name} data").materials.append(mat)
    return obj


def plane(name: str, width: float, height: float, mat: bpy.types.Material) -> bpy.types.Object:
    _ = bpy.ops.mesh.primitive_plane_add(size=1)
    obj = active_object("primitive_plane_add")
    obj.name = name
    obj.scale = (width, height, 1)
    _ = bpy.ops.object.transform_apply(scale=True)
    expect(obj.data, bpy.types.Mesh, f"{name} data").materials.append(mat)
    return obj


def build_laptop(screen_image: Path) -> tuple[bpy.types.Object, bpy.types.Object]:
    """Returns (root, hinge): rotate the root to turn the laptop, the hinge's X rotation to open the lid."""
    aluminium = material("Aluminium", (0.70, 0.70, 0.72), 1.0, 0.5)
    well = material("KeyboardWell", (0.42, 0.42, 0.44), 0.8, 0.5)
    dark = material("Keys", (0.03, 0.03, 0.035), 0.0, 0.6)
    bezel = material("Bezel", (0.012, 0.012, 0.014), 0.0, 0.18)
    trackpad = material("Trackpad", (0.70, 0.70, 0.72), 0.9, 0.38)

    root = bpy.data.objects.new("Laptop", None)
    bpy.context.collection.objects.link(root)

    base = rounded_box("Base", BASE, 0.005, aluminium)
    base.location = (0, 0, BASE.z / 2)
    base.parent = root

    keyboard = plane("KeyboardWell", BASE.x * 0.86, BASE.y * 0.42, well)
    keyboard.location = (0, BASE.y * 0.12, BASE.z + 0.0002)
    keyboard.parent = root

    columns, rows = 14, 5
    pitch_x = BASE.x * 0.85 / columns
    pitch_y = BASE.y * 0.41 / rows
    key = rounded_box("Key", Vector((pitch_x * 0.84, pitch_y * 0.84, 0.001)), 0.0004, dark)
    key.location = (-BASE.x * 0.425 + pitch_x / 2, BASE.y * 0.12 - BASE.y * 0.205 + pitch_y / 2, BASE.z + 0.0005)
    for axis, count, offset in ((0, columns, pitch_x), (1, rows, pitch_y)):
        array = expect(key.modifiers.new(f"Array{axis}", "ARRAY"), bpy.types.ArrayModifier, f"key array {axis}")
        array.use_relative_offset = False
        array.use_constant_offset = True
        array.constant_offset_displace = (offset, 0, 0) if axis == 0 else (0, offset, 0)
        array.count = count
    key.parent = root

    pad = plane("Trackpad", BASE.x * 0.4, BASE.y * 0.3, trackpad)
    pad.location = (0, -BASE.y * 0.29, BASE.z + 0.0003)
    pad.parent = root

    hinge = bpy.data.objects.new("Hinge", None)
    bpy.context.collection.objects.link(hinge)
    hinge.location = (0, BASE.y / 2, BASE.z + 0.0015)
    hinge.parent = root

    lid_height = BASE.y * 0.985
    lid = rounded_box("Lid", Vector((BASE.x, LID_THICKNESS, lid_height)), 0.004, aluminium)
    lid.location = (0, -LID_THICKNESS / 2, lid_height / 2)
    lid.parent = hinge

    inner = plane("BezelGlass", BASE.x * 0.985, lid_height * 0.975, bezel)
    inner.rotation_euler = (math.radians(90), 0, 0)
    inner.location = (0, -LID_THICKNESS - 0.0004, lid_height / 2)
    inner.parent = hinge

    screen_width = BASE.x * 0.93
    screen = plane("Screen", screen_width, screen_width / SCREEN_ASPECT, screen_material(screen_image))
    screen.rotation_euler = (math.radians(90), 0, 0)
    screen.location = (0, -LID_THICKNESS - 0.0008, lid_height / 2 + 0.002)
    screen.parent = hinge
    return root, hinge


def add_lights() -> None:
    world = bpy.data.worlds.new("Studio")
    world.use_nodes = True
    background = node_tree(world.node_tree, "Studio").nodes["Background"]
    set_color(background, "Color", (0.98, 0.95, 0.93, 1.0))
    set_float(background, "Strength", 0.4)
    bpy.context.scene.world = world

    def area(
        name: str, location: tuple[float, float, float], color: tuple[float, float, float], energy: float, size: float
    ) -> None:
        data = expect(bpy.data.lights.new(name, type="AREA"), bpy.types.AreaLight, f"{name} light")
        data.energy = energy
        data.color = color
        data.size = size
        obj = bpy.data.objects.new(name, data)
        bpy.context.collection.objects.link(obj)
        obj.location = location
        direction = Vector((0, 0, 0.08)) - obj.location
        obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()

    area("Key", (-0.55, -0.6, 0.75), (1.0, 0.93, 0.88), 38, 0.8)
    area("Rim", (0.6, 0.55, 0.45), (0.80, 0.74, 1.0), 30, 0.6)
    area("Fill", (0.7, -0.5, 0.2), (1.0, 0.85, 0.8), 10, 1.0)


def add_camera() -> bpy.types.Object:
    data = bpy.data.cameras.new("Camera")
    data.lens = 50
    camera = bpy.data.objects.new("Camera", data)
    bpy.context.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    return camera


def ease_out(t: float) -> float:
    clamped = min(max(t, 0.0), 1.0)
    return 1 - (1 - clamped) ** 3


def ease_in_out(t: float) -> float:
    clamped = min(max(t, 0.0), 1.0)
    return clamped * clamped * (3 - 2 * clamped)


def animate(root: bpy.types.Object, hinge: bpy.types.Object, camera: bpy.types.Object, frames: int) -> None:
    """Lid opens over the first 1.3 s while the laptop turns towards the viewer; then a slow push-in."""
    target = Vector((0, -0.05, 0.055))
    for frame in range(1, frames + 1):
        open_t = ease_out((frame - 1) / 40)
        drift_t = ease_in_out((frame - 1) / max(frames - 1, 1))
        # Closed lid is +90° (flat on the base); open is about -18° past upright.
        hinge.rotation_euler = (math.radians(90 - 108 * open_t), 0, 0)
        root.rotation_euler = (0, 0, math.radians(-24 + 18 * open_t + 4 * drift_t))
        distance = 1.06 - 0.10 * drift_t
        height = 0.30 - 0.05 * open_t
        camera.location = target + Vector((0.0, -distance, height))
        camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
        hinge.keyframe_insert("rotation_euler", frame=frame)
        root.keyframe_insert("rotation_euler", frame=frame)
        camera.keyframe_insert("location", frame=frame)
        camera.keyframe_insert("rotation_euler", frame=frame)


def configure_render(out_dir: Path, frames: int) -> None:
    scene = bpy.context.scene
    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.taa_render_samples = 64
    scene.eevee.use_raytracing = True
    scene.render.resolution_x = WIDTH
    scene.render.resolution_y = HEIGHT
    scene.render.resolution_percentage = 100
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "WEBP"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.quality = 92
    # Standard keeps the app's UI colours on the display as they are on a real screen.
    scene.view_settings.view_transform = "Standard"
    scene.frame_start = 1
    scene.frame_end = frames
    scene.render.fps = 30
    scene.render.filepath = str(out_dir / "####")


def main() -> None:
    args = parse_args(sys.argv)
    if not args.screen_image.exists():
        raise FileNotFoundError(f"Screen image not found: {args.screen_image}")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    root, hinge = build_laptop(args.screen_image)
    add_lights()
    camera = add_camera()
    animate(root, hinge, camera, args.frames)
    configure_render(args.out_dir, args.frames)
    if args.only:
        render_frames(args.out_dir, args.only)
    else:
        bpy.ops.render.render(animation=True)


def render_frames(out_dir: Path, frames: tuple[int, ...]) -> None:
    scene = bpy.context.scene
    for frame in frames:
        scene.frame_set(frame)
        scene.render.filepath = str(out_dir / f"{frame:04d}")
        bpy.ops.render.render(write_still=True)


# devices.py imports this module for its laptop model; Blender runs it as __main__.
if __name__ == "__main__":
    main()
