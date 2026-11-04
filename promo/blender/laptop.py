"""Render the promo's hero shot: a generic aluminium laptop opening, with the Gistsmith home screen on its display.

Run headless (Blender 5.x):
  blender --background --factory-startup --python promo/blender/laptop.py -- <screen-image> <out-dir> <frames> [<f1,f2,…>]

Writes `<out-dir>/####.webp` (RGBA, transparent background, 1920x1080) for frames 1..<frames>. The model is built from
primitives here, so no third-party model or Apple asset is involved. Every value is keyed to the frame number, so the
sequence is deterministic and the Remotion scene can play it frame for frame.
"""

import math
import sys
from dataclasses import dataclass
from pathlib import Path

import bpy
from mathutils import Vector

WIDTH = 1920
HEIGHT = 1080

BASE = Vector((0.304, 0.212, 0.011))
LID_THICKNESS = 0.006
SCREEN_ASPECT = 2400 / 1560


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
    screen, out, frames = rest[:3]
    only = tuple(int(value) for value in rest[3].split(",")) if len(rest) > 3 else ()
    return RenderArgs(screen_image=Path(screen).resolve(), out_dir=Path(out).resolve(), frames=int(frames), only=only)


def material(name: str, color: tuple[float, float, float], metallic: float, roughness: float) -> bpy.types.Material:
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*color, 1.0)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = roughness
    return mat


def screen_material(image_path: Path) -> bpy.types.Material:
    """An emissive screenshot under a faint gloss, so the display shows true colours and still catches a highlight."""
    mat = bpy.data.materials.new("Screen")
    mat.use_nodes = True
    nodes = mat.node_tree.nodes
    links = mat.node_tree.links
    bsdf = nodes["Principled BSDF"]
    texture = nodes.new("ShaderNodeTexImage")
    texture.image = bpy.data.images.load(str(image_path))
    texture.interpolation = "Cubic"
    # Black base + emission 1.0 under the Standard view transform shows the screenshot's own sRGB colours.
    bsdf.inputs["Base Color"].default_value = (0, 0, 0, 1)
    links.new(texture.outputs["Color"], bsdf.inputs["Emission Color"])
    bsdf.inputs["Emission Strength"].default_value = 1.0
    bsdf.inputs["Roughness"].default_value = 0.12
    bsdf.inputs["Specular IOR Level"].default_value = 0.12
    return mat


def rounded_box(name: str, size: Vector, bevel: float, mat: bpy.types.Material) -> bpy.types.Object:
    bpy.ops.mesh.primitive_cube_add(size=1)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = size
    bpy.ops.object.transform_apply(scale=True)
    modifier = obj.modifiers.new("Bevel", "BEVEL")
    modifier.width = bevel
    modifier.segments = 8
    modifier.limit_method = "NONE"
    bpy.ops.object.shade_smooth()
    obj.data.materials.append(mat)
    return obj


def plane(name: str, width: float, height: float, mat: bpy.types.Material) -> bpy.types.Object:
    bpy.ops.mesh.primitive_plane_add(size=1)
    obj = bpy.context.active_object
    obj.name = name
    obj.scale = (width, height, 1)
    bpy.ops.object.transform_apply(scale=True)
    obj.data.materials.append(mat)
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
        array = key.modifiers.new(f"Array{axis}", "ARRAY")
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
    background = world.node_tree.nodes["Background"]
    background.inputs["Color"].default_value = (0.98, 0.95, 0.93, 1.0)
    background.inputs["Strength"].default_value = 0.4
    bpy.context.scene.world = world

    def area(name: str, location: tuple[float, float, float], color: tuple[float, float, float], energy: float, size: float) -> None:
        data = bpy.data.lights.new(name, type="AREA")
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


main()
