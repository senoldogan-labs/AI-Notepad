"""Render a still of Gistsmith on a laptop, a phone and a watch, on the site's Warm Ember background.

Run headless (Blender 5.x), normally through devices.sh (which also writes the WebP copies the site uses):
  blender --background --factory-startup --python-exit-code 1 --python promo/blender/devices.py -- \
    <mac-screen> <phone-screen> <watch-screen> <out-dir> <samples> <percent>

Writes `<out-dir>/devices-wide.png` (2400x1350) and `<out-dir>/devices-portrait.png` (1080x1350). The laptop comes from
laptop.py; the phone and the watch are generic rounded slabs built here, so no third-party model or Apple asset is
involved. Cycles renders the devices over a shadow-catcher floor with a transparent film, then the render is laid over
a background drawn here: near-black with static copper and sand glows and a fine seeded grain, like the site's hero.

The phone screen is `web/src/assets/screenshots/iphone-<name>.webp` (made by web/scripts/make-iphone-shots.ts): its
drawn frame is skipped by mapping only the inner screen rectangle, so the model's own body is the only frame.
"""

import math
import sys
from dataclasses import dataclass
from pathlib import Path

import bmesh
import bpy
import numpy as np
import numpy.typing as npt
from mathutils import Vector

# Blender does not put the script's folder on the import path; laptop.py lives next to this file.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from laptop import (
    BlenderTypeError,
    active_object,
    build_laptop,
    expect,
    material,
    node_tree,
    set_color,
    set_float,
)

# <mac-screen> <phone-screen> <watch-screen> <out-dir> <samples> <percent>
REQUIRED_ARGS = 6
CORNER_SEGMENTS = 12

# The phone screenshot's drawn frame (make-iphone-shots.ts): 840 px of screen inside 888, so 24 px per side.
PHONE_SHOT_SCREEN = 840
PHONE_SHOT_FRAME = 24
PHONE_SCREEN_CORNER = 62 / 440

Rgb = tuple[float, float, float]
FloatImage = npt.NDArray[np.float32]


@dataclass(frozen=True)
class RenderArgs:
    mac_screen: Path
    phone_screen: Path
    watch_screen: Path
    out_dir: Path
    samples: int
    # Resolution percentage: 100 for the final images, lower for a quick composition check.
    percent: int


@dataclass(frozen=True)
class Shot:
    """One framing of the scene: output name, size, and where the camera stands relative to its target."""

    name: str
    width: int
    height: int
    lens: float
    camera: Vector
    target: Vector


@dataclass(frozen=True)
class Glow:
    """A soft elliptical glow on the background, in image fractions (x right, y down) and sRGB colour."""

    x: float
    y: float
    radius_x: float
    radius_y: float
    color: Rgb
    strength: float


SHOTS = (
    Shot("devices-wide", 2400, 1350, 50, Vector((0.08, -0.91, 0.27)), Vector((0.0, -0.03, 0.082))),
    Shot("devices-portrait", 1080, 1350, 50, Vector((0.07, -1.22, 0.42)), Vector((0.005, -0.05, 0.112))),
)

BACKGROUND_BASE: Rgb = (0.055, 0.043, 0.036)
GLOWS = (
    Glow(0.40, 0.30, 0.36, 0.30, (0.647, 0.400, 0.294), 0.85),  # copper behind the laptop (--ember-500)
    Glow(0.62, 0.16, 0.18, 0.14, (0.824, 0.706, 0.557), 0.55),  # sand highlight (--ember-200)
    Glow(0.02, 1.00, 0.34, 0.26, (0.494, 0.263, 0.188), 0.60),  # deep corner (--ember-700)
)
GRAIN = 0.022
GRAIN_SEED = 20261111


def parse_args(argv: list[str]) -> RenderArgs:
    if "--" not in argv or len(argv) - argv.index("--") - 1 != REQUIRED_ARGS:
        raise SystemExit(
            "Usage: blender --background --python devices.py -- "
            + "<mac-screen> <phone-screen> <watch-screen> <out-dir> <samples> <percent>"
        )
    mac, phone, watch, out, samples, percent = argv[argv.index("--") + 1 :]
    return RenderArgs(
        mac_screen=Path(mac).resolve(),
        phone_screen=Path(phone).resolve(),
        watch_screen=Path(watch).resolve(),
        out_dir=Path(out).resolve(),
        samples=int(samples),
        percent=int(percent),
    )


def rounded_rect_points(width: float, height: float, radius: float) -> list[tuple[float, float]]:
    """Outline of a rounded rectangle centred on the origin, counter-clockwise."""
    corners = (
        (width / 2 - radius, height / 2 - radius, 0.0),
        (-width / 2 + radius, height / 2 - radius, 90.0),
        (-width / 2 + radius, -height / 2 + radius, 180.0),
        (width / 2 - radius, -height / 2 + radius, 270.0),
    )
    points: list[tuple[float, float]] = []
    for cx, cy, start in corners:
        for step in range(CORNER_SEGMENTS + 1):
            angle = math.radians(start + 90 * step / CORNER_SEGMENTS)
            points.append((cx + radius * math.cos(angle), cy + radius * math.sin(angle)))
    return points


@dataclass(frozen=True)
class RoundedRect:
    width: float
    height: float
    radius: float


def rounded_mesh(
    name: str, shape: RoundedRect, depth: float, uv_rect: tuple[float, float, float, float]
) -> bpy.types.Object:
    """A rounded rectangle in the XY plane, extruded `depth` along +Z when depth > 0 (a flat face otherwise).

    UVs map the outline's bounds onto `uv_rect` (u0, v0, u1, v1) of the texture, so a screenshot fills the shape.
    """
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    width, height = shape.width, shape.height
    verts = [bm.verts.new((x, y, 0.0)) for x, y in rounded_rect_points(width, height, shape.radius)]
    face = bm.faces.new(verts)
    if depth > 0:
        extruded = bmesh.ops.extrude_face_region(bm, geom=[face])
        moved = [item for item in extruded["geom"] if isinstance(item, bmesh.types.BMVert)]
        _ = bmesh.ops.translate(bm, verts=moved, vec=(0.0, 0.0, depth))
        _ = bmesh.ops.recalc_face_normals(bm, faces=list(bm.faces))
    uv_layer = bm.loops.layers.uv.new("UVMap")
    u0, v0, u1, v1 = uv_rect
    for each in bm.faces:
        for loop in each.loops:
            loop[uv_layer].uv = (
                u0 + (loop.vert.co.x / width + 0.5) * (u1 - u0),
                v0 + (loop.vert.co.y / height + 0.5) * (v1 - v0),
            )
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    bpy.context.collection.objects.link(obj)
    return obj


def soften(obj: bpy.types.Object, bevel: float) -> None:
    """Rounds the slab's sharp edges and shades it smooth by angle."""
    modifier = expect(obj.modifiers.new("Bevel", "BEVEL"), bpy.types.BevelModifier, f"{obj.name} bevel")
    modifier.width = bevel
    modifier.segments = 6
    modifier.limit_method = "ANGLE"
    modifier.angle_limit = math.radians(50)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    _ = bpy.ops.object.modifier_apply(modifier=modifier.name)
    _ = bpy.ops.object.shade_smooth_by_angle(angle=math.radians(35))
    obj.select_set(False)


def assign(obj: bpy.types.Object, mat: bpy.types.Material) -> None:
    expect(obj.data, bpy.types.Mesh, f"{obj.name} data").materials.append(mat)


def screen_material(name: str, image_path: Path) -> bpy.types.Material:
    """Emissive screenshot (alpha over black) under a faint gloss: true colours that still catch a highlight."""
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    tree = node_tree(mat.node_tree, name)
    bsdf = tree.nodes["Principled BSDF"]
    texture = expect(tree.nodes.new("ShaderNodeTexImage"), bpy.types.ShaderNodeTexImage, f"{name} texture node")
    texture.image = bpy.data.images.load(str(image_path))
    texture.interpolation = "Cubic"
    texture.extension = "EXTEND"
    mix = expect(tree.nodes.new("ShaderNodeMix"), bpy.types.ShaderNodeMix, f"{name} alpha mix")
    mix.data_type = "RGBA"
    set_color_input(mix, 6, (0, 0, 0, 1))
    link_index(tree, texture, "Alpha", mix, 0)
    link_index(tree, texture, "Color", mix, 7)
    set_color(bsdf, "Base Color", (0, 0, 0, 1))
    link_output_index(tree, mix, 2, bsdf, "Emission Color")
    set_float(bsdf, "Emission Strength", 1.0)
    set_float(bsdf, "Roughness", 0.1)
    set_float(bsdf, "Specular IOR Level", 0.25)
    return mat


def set_color_input(node: bpy.types.Node, index: int, rgba: tuple[float, float, float, float]) -> None:
    expect(node.inputs[index], bpy.types.NodeSocketColor, f"{node.name}[{index}]").default_value.foreach_set(rgba)


def link_index(
    tree: bpy.types.ShaderNodeTree, source: bpy.types.Node, output: str, target: bpy.types.Node, index: int
) -> None:
    # ShaderNodeMix repeats its socket names per data type, so its inputs are picked by index (0 factor, 6/7 colours).
    _ = tree.links.new(source.outputs[output], target.inputs[index])


def link_output_index(
    tree: bpy.types.ShaderNodeTree, source: bpy.types.Node, index: int, target: bpy.types.Node, socket: str
) -> None:
    # The mix node's colour result is output 2 (its outputs, like its inputs, repeat names per data type).
    _ = tree.links.new(source.outputs[index], target.inputs[socket])


def build_phone(screen_image: Path) -> bpy.types.Object:
    """A generic modern phone: rounded graphite slab, black glass, the screenshot's inner screen. Front faces +Z."""
    root = bpy.data.objects.new("Phone", None)
    bpy.context.collection.objects.link(root)
    screen_width = 0.0646
    screen_height = screen_width * (1825 / PHONE_SHOT_SCREEN)
    bezel = 0.0032
    width, height, depth = screen_width + 2 * bezel, screen_height + 2 * bezel, 0.0080
    screen_radius = screen_width * PHONE_SCREEN_CORNER
    body = rounded_mesh("PhoneBody", RoundedRect(width, height, screen_radius + bezel), depth, (0, 0, 1, 1))
    soften(body, 0.0018)
    assign(body, material("Graphite", (0.16, 0.15, 0.145), 1.0, 0.32))
    body.parent = root
    glass = rounded_mesh(
        "PhoneGlass", RoundedRect(width - 0.0016, height - 0.0016, screen_radius + bezel - 0.0008), 0, (0, 0, 1, 1)
    )
    glass.location = (0, 0, depth + 0.00005)
    assign(glass, material("PhoneBezel", (0.008, 0.008, 0.009), 0.0, 0.08))
    glass.parent = root
    # Map the inner screen of the framed screenshot (888 x 1873 px, 24 px frame) onto the screen face.
    total_w = PHONE_SHOT_SCREEN + 2 * PHONE_SHOT_FRAME
    total_h = 1825 + 2 * PHONE_SHOT_FRAME
    uv = (
        PHONE_SHOT_FRAME / total_w,
        PHONE_SHOT_FRAME / total_h,
        1 - PHONE_SHOT_FRAME / total_w,
        1 - PHONE_SHOT_FRAME / total_h,
    )
    screen = rounded_mesh("PhoneScreen", RoundedRect(screen_width, screen_height, screen_radius), 0, uv)
    screen.location = (0, 0, depth + 0.0001)
    assign(screen, screen_material("PhoneScreenMat", screen_image))
    screen.parent = root
    return root


def build_watch(screen_image: Path) -> bpy.types.Object:
    """A generic rounded-square watch on a closed sport band. Front faces +Z, band loop behind the case (-Z)."""
    root = bpy.data.objects.new("Watch", None)
    bpy.context.collection.objects.link(root)
    screen_width = 0.0335
    screen_height = screen_width * 496 / 416
    bezel = 0.0026
    width, height, depth = screen_width + 2 * bezel, screen_height + 2 * bezel, 0.0105
    case_metal = material("WatchCase", (0.62, 0.45, 0.36), 1.0, 0.28)
    body = rounded_mesh("WatchCase", RoundedRect(width, height, 0.0105), depth, (0, 0, 1, 1))
    soften(body, 0.0035)
    assign(body, case_metal)
    body.parent = root
    glass = rounded_mesh("WatchGlass", RoundedRect(width - 0.0012, height - 0.0012, 0.0098), 0, (0, 0, 1, 1))
    glass.location = (0, 0, depth + 0.00005)
    assign(glass, material("WatchBezel", (0.006, 0.006, 0.007), 0.0, 0.06))
    glass.parent = root
    screen = rounded_mesh("WatchScreen", RoundedRect(screen_width, screen_height, 0.0078), 0, (0, 0, 1, 1))
    screen.location = (0, 0, depth + 0.0001)
    assign(screen, screen_material("WatchScreenMat", screen_image))
    screen.parent = root

    _ = bpy.ops.mesh.primitive_cylinder_add(radius=0.0034, depth=0.0035, vertices=32)
    crown = active_object("primitive_cylinder_add")
    crown.name = "Crown"
    crown.rotation_euler = (0, math.radians(90), 0)
    crown.location = (width / 2 + 0.0012, height * 0.18, depth * 0.55)
    assign(crown, case_metal)
    crown.parent = root

    build_band(root, height, depth)
    return root


def build_band(root: bpy.types.Object, case_height: float, case_depth: float) -> None:
    """The band: the back half of a flattened torus whose ends sit inside the case's top and bottom edges."""
    reach_y = case_height / 2 - 0.0028
    reach_z = 0.030
    thickness = 0.0025
    strap_width = 0.0225
    _ = bpy.ops.mesh.primitive_torus_add(
        major_radius=reach_y, minor_radius=thickness, major_segments=96, minor_segments=16
    )
    band = active_object("primitive_torus_add")
    band.name = "Band"
    mesh = expect(band.data, bpy.types.Mesh, "band data")
    bm = bmesh.new()
    bm.from_mesh(mesh)
    # Torus axis Z → X; ring in the YZ plane, stretched to reach_z deep and strap_width wide, front half removed.
    for vert in bm.verts:
        x, y, z = vert.co.x, vert.co.y, vert.co.z
        radial = math.hypot(x, y)
        angle = math.atan2(y, x)
        ring = radial - reach_y
        vert.co = Vector(
            (
                z * strap_width / (2 * thickness),
                (reach_y + ring) * math.sin(angle),
                (reach_z + ring) * math.cos(angle) * 1.0,
            )
        )
    front: list[bmesh.types.BMVert | bmesh.types.BMEdge | bmesh.types.BMFace] = [
        vert for vert in bm.verts if vert.co.z > 0
    ]
    _ = bmesh.ops.delete(bm, geom=front, context="VERTS")
    for vert in bm.verts:
        vert.co.z += case_depth * 0.45
    bm.to_mesh(mesh)
    bm.free()
    mesh.shade_smooth()
    assign(band, material("Band", (0.075, 0.062, 0.055), 0.0, 0.55))
    band.parent = root


def retint(name: str, color: Rgb, roughness: float) -> None:
    """Recolours a material laptop.py made: the still uses a darker aluminium that sits on the near-black background."""
    mat = bpy.data.materials.get(name)
    if mat is None:
        raise BlenderTypeError(f"laptop.py made no material named {name}")
    bsdf = node_tree(mat.node_tree, name).nodes["Principled BSDF"]
    set_color(bsdf, "Base Color", (*color, 1.0))
    set_float(bsdf, "Roughness", roughness)


def place(obj: bpy.types.Object, location: tuple[float, float, float], lean_back: float, turn: float) -> None:
    """Stands a +Z-facing device upright facing -Y, leaned back by `lean_back` degrees and turned by `turn`."""
    obj.location = location
    obj.rotation_euler = (math.radians(90 - lean_back), 0, math.radians(turn))


def add_floor() -> None:
    _ = bpy.ops.mesh.primitive_plane_add(size=6)
    floor = active_object("primitive_plane_add")
    floor.name = "Floor"
    floor.is_shadow_catcher = True


def add_lights() -> None:
    world = bpy.data.worlds.new("Ember")
    world.use_nodes = True
    background = node_tree(world.node_tree, "Ember").nodes["Background"]
    set_color(background, "Color", (0.30, 0.17, 0.11, 1.0))
    set_float(background, "Strength", 0.22)
    bpy.context.scene.world = world

    def area(name: str, location: tuple[float, float, float], color: Rgb, energy: float, size: float) -> None:
        data = expect(bpy.data.lights.new(name, type="AREA"), bpy.types.AreaLight, f"{name} light")
        data.energy = energy
        data.color = color
        data.size = size
        obj = bpy.data.objects.new(name, data)
        bpy.context.collection.objects.link(obj)
        obj.location = location
        direction = Vector((0, 0, 0.08)) - obj.location
        obj.rotation_euler = direction.to_track_quat("-Z", "Y").to_euler()

    area("Key", (-0.6, -0.55, 0.8), (1.0, 0.90, 0.82), 26, 0.9)
    area("Rim", (0.55, 0.6, 0.5), (1.0, 0.70, 0.52), 40, 0.6)
    area("RimLeft", (-0.6, 0.5, 0.35), (1.0, 0.70, 0.50), 22, 0.5)
    area("Fill", (0.8, -0.6, 0.25), (1.0, 0.86, 0.78), 12, 1.2)


def configure_cycles(samples: int) -> None:
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    cycles = scene.cycles
    cycles.samples = samples
    cycles.use_denoising = True
    cycles.use_adaptive_sampling = True
    scene.render.film_transparent = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.color_depth = "8"
    # Standard keeps the app's UI colours on the displays as they are on a real screen.
    scene.view_settings.view_transform = "Standard"
    scene.view_settings.look = "None"


def aim_camera(camera: bpy.types.Object, shot: Shot) -> None:
    data = expect(camera.data, bpy.types.Camera, "camera data")
    data.lens = shot.lens
    data.sensor_fit = "HORIZONTAL" if shot.width >= shot.height else "VERTICAL"
    camera.location = shot.camera
    camera.rotation_euler = (shot.target - shot.camera).to_track_quat("-Z", "Y").to_euler()


def background(width: int, height: int) -> FloatImage:
    """Near-black with soft copper and sand glows and a seeded grain, as rows top to bottom (H x W x 3, sRGB)."""
    ys, xs = np.mgrid[0:height, 0:width].astype(np.float32)
    # Glow sizes follow the image width so the wide and portrait images share the same light.
    scale = float(max(width, height))
    image = np.empty((height, width, 3), dtype=np.float32)
    image[:] = np.array(BACKGROUND_BASE, dtype=np.float32)
    for glow in GLOWS:
        dx = (xs - glow.x * width) / (glow.radius_x * scale)
        dy = (ys - glow.y * height) / (glow.radius_y * scale)
        weight = (np.exp(-(dx * dx + dy * dy) * 2.2) * glow.strength)[..., None]
        image = image + (np.array(glow.color, dtype=np.float32) - image) * weight
    rng = np.random.default_rng(GRAIN_SEED)
    grain = rng.normal(0.0, GRAIN, size=(height, width, 1)).astype(np.float32)
    return np.clip(image + grain, 0.0, 1.0).astype(np.float32)


def composite(render_path: Path, out_path: Path, width: int, height: int) -> None:
    """Lays the transparent render (devices + caught shadows) over the background and saves an opaque PNG."""
    rendered = bpy.data.images.load(str(render_path))
    # Raw stored values (sRGB-encoded, straight alpha), the same space the background is drawn in.
    expect(
        rendered.colorspace_settings, bpy.types.ColorManagedInputColorspaceSettings, "render colour space"
    ).is_data = True
    pixels = np.empty(width * height * 4, dtype=np.float32)
    # The stubs leave foreach_get's argument untyped; Blender fills any writable float buffer.
    rendered.pixels.foreach_get(pixels)  # pyright: ignore[reportUnknownMemberType]
    # Blender stores rows bottom to top; flip to match the background.
    layer = pixels.reshape(height, width, 4)[::-1]
    alpha = layer[..., 3:4]
    merged = layer[..., :3] * alpha + background(width, height) * (1 - alpha)
    rgba = np.concatenate([merged, np.ones((height, width, 1), dtype=np.float32)], axis=2)[::-1]
    result = bpy.data.images.new(out_path.stem, width=width, height=height, alpha=False)
    # The stubs type the argument as a Sequence; Blender reads any float buffer, and a NumPy array is the fast path.
    result.pixels.foreach_set(np.ascontiguousarray(rgba).reshape(-1))  # pyright: ignore[reportArgumentType]
    result.filepath_raw = str(out_path)
    result.file_format = "PNG"
    result.save()
    bpy.data.images.remove(rendered)


def build_scene(args: RenderArgs) -> bpy.types.Object:
    root, hinge = build_laptop(args.mac_screen)
    retint("Aluminium", (0.30, 0.29, 0.285), 0.42)
    retint("KeyboardWell", (0.16, 0.155, 0.15), 0.5)
    retint("Trackpad", (0.33, 0.32, 0.315), 0.36)
    root.location = (-0.06, 0.07, 0)
    root.rotation_euler = (0, 0, math.radians(10))
    hinge.rotation_euler = (math.radians(-14), 0, 0)

    phone = build_phone(args.phone_screen)
    place(phone, (0.150, -0.11, 0.0), 14, 14)
    # Lift the phone so its lower edge, not its centre, rests on the floor.
    phone.location.z = 0.0742 * math.cos(math.radians(14)) + 0.0005

    watch = build_watch(args.watch_screen)
    place(watch, (-0.035, -0.20, 0.0), 10, -10)
    watch.location.z = 0.0262

    add_floor()
    add_lights()
    data = bpy.data.cameras.new("Camera")
    camera = bpy.data.objects.new("Camera", data)
    bpy.context.collection.objects.link(camera)
    bpy.context.scene.camera = camera
    return camera


def main() -> None:
    args = parse_args(sys.argv)
    for path in (args.mac_screen, args.phone_screen, args.watch_screen):
        if not path.exists():
            raise FileNotFoundError(f"Screen image not found: {path}")
    args.out_dir.mkdir(parents=True, exist_ok=True)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    camera = build_scene(args)
    configure_cycles(args.samples)
    scene = bpy.context.scene
    for shot in SHOTS:
        aim_camera(camera, shot)
        width = shot.width * args.percent // 100
        height = shot.height * args.percent // 100
        scene.render.resolution_x = width
        scene.render.resolution_y = height
        scene.render.resolution_percentage = 100
        layer_path = args.out_dir / f"{shot.name}-layer.png"
        scene.render.filepath = str(layer_path)
        _ = bpy.ops.render.render(write_still=True)
        if not layer_path.exists():
            raise BlenderTypeError(f"Blender wrote no render at {layer_path}")
        composite(layer_path, args.out_dir / f"{shot.name}.png", width, height)
        layer_path.unlink()


if __name__ == "__main__":
    main()
