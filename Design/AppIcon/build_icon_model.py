"""Build the 3D Ferry app icon model and render the AppIcon.icon layers.

Usage (from the repository root):
    blender -b -P Design/AppIcon/build_icon_model.py -- [--render | --showcase] [--preview]

Writes Design/AppIcon/FerryIcon.blend. With --render it also writes:
  - Ferry/AppIcon.icon/Assets/sea.png    background layer (ocean; the ferry only appears in reflections and shadows)
  - Ferry/AppIcon.icon/Assets/ferry.png  foreground layer (ferry on transparency; the ocean catches its shadow)
  - Design/AppIcon/FerryModel.png        studio showcase render
--showcase renders only the showcase. --preview renders at low resolution and sample count into Design/AppIcon for quick iteration.
"""

import math
import os
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ASSETS = os.path.join(ROOT, "Ferry", "AppIcon.icon", "Assets")
OUT_DIR = os.path.join(ROOT, "Design", "AppIcon")

LENGTH, BEAM = 7.2, 3.6

PALETTE = {
    "white": "#F4F6F8",
    "hull": "#1F5FD6",
    "boot": "#D9363E",
    "deck": "#5E8088",
    "glass": "#22385A",
    "yellow": "#FFC53D",
    "black": "#1D2129",
    "foam": "#FFFFFF",
    "sea": "#1E8AC8",
}
CONTAINER_COLORS = ["#F59E0B", "#14B8A6", "#E5484D"]


# Materials --------------------------------------------------------------------------------------

def linear(hex_value):
    value = hex_value.lstrip("#")
    srgb = [int(value[i : i + 2], 16) / 255 for i in (0, 2, 4)]
    return tuple(c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb)


def new_material(name):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    return mat, mat.node_tree.nodes["Principled BSDF"]


def material(name, color, roughness=0.32, coat=0.5, metallic=0.0, emission=0.0):
    mat, bsdf = new_material(name)
    bsdf.inputs["Base Color"].default_value = (*linear(color), 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.08
    if emission:
        bsdf.inputs["Emission Color"].default_value = (*linear(color), 1.0)
        bsdf.inputs["Emission Strength"].default_value = emission
    return mat


def banded_material(name, z_min, z_max, bands, roughness=0.3, coat=0.6):
    """Hard color bands along the object's local Z; bands are (start z, color) in ascending order."""
    mat, bsdf = new_material(name)
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Coat Weight"].default_value = coat
    bsdf.inputs["Coat Roughness"].default_value = 0.08
    coords = nodes.new("ShaderNodeTexCoord")
    separate = nodes.new("ShaderNodeSeparateXYZ")
    remap = nodes.new("ShaderNodeMapRange")
    remap.inputs["From Min"].default_value = z_min
    remap.inputs["From Max"].default_value = z_max
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.interpolation = "CONSTANT"
    elements = ramp.color_ramp.elements
    while len(elements) < len(bands):
        elements.new(1.0)
    for element, (z, color) in zip(elements, bands):
        element.position = (z - z_min) / (z_max - z_min)
        element.color = (*linear(color), 1.0)
    links.new(coords.outputs["Object"], separate.inputs["Vector"])
    links.new(separate.outputs["Z"], remap.inputs["Value"])
    links.new(remap.outputs["Result"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    return mat


def sea_material():
    mat, bsdf = new_material("sea")
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf.inputs["Roughness"].default_value = 0.06
    bsdf.inputs["IOR"].default_value = 1.33
    foam = nodes.new("ShaderNodeAttribute")
    foam.attribute_name = "foam"
    foam_ramp = nodes.new("ShaderNodeValToRGB")
    foam_ramp.color_ramp.elements[0].position = 0.35
    foam_ramp.color_ramp.elements[1].position = 0.9
    mix = nodes.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["A"].default_value = (*linear(PALETTE["sea"]), 1.0)
    mix.inputs["B"].default_value = (0.9, 0.95, 1.0, 1.0)
    noise = nodes.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 18.0
    noise.inputs["Detail"].default_value = 6.0
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.08
    links.new(foam.outputs["Fac"], foam_ramp.inputs["Fac"])
    links.new(foam_ramp.outputs["Color"], mix.inputs["Factor"])
    links.new(mix.outputs["Result"], bsdf.inputs["Base Color"])
    links.new(noise.outputs["Fac"], bump.inputs["Height"])
    links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    return mat


# Geometry helpers -------------------------------------------------------------------------------

class Parts:
    """Collects primitive geometry per material and emits one mesh object per material."""

    def __init__(self, prefix):
        self.prefix = prefix
        self.meshes = {}

    def bm(self, mat):
        if mat.name not in self.meshes:
            self.meshes[mat.name] = (bmesh.new(), mat)
        return self.meshes[mat.name][0]

    def box(self, mat, center, size, rotation=None):
        matrix = Matrix.Translation(center) @ (rotation or Matrix.Identity(4)) @ Matrix.Diagonal((*size, 1.0))
        bmesh.ops.create_cube(self.bm(mat), size=1.0, matrix=matrix)

    def cylinder(self, mat, base, axis, radius, height, radius_top=None, segments=24):
        axis = Vector(axis).normalized()
        rotation = axis.to_track_quat("Z", "Y").to_matrix().to_4x4()
        matrix = Matrix.Translation(Vector(base) + axis * height / 2) @ rotation
        verts = bmesh.ops.create_cone(
            self.bm(mat), cap_ends=True, segments=segments, radius1=radius,
            radius2=radius if radius_top is None else radius_top, depth=height, matrix=matrix,
        )["verts"]
        for face in {face for vert in verts for face in vert.link_faces}:
            face.normal_update()
            face.smooth = abs(face.normal.dot(axis)) < 0.5

    def sphere(self, mat, center, radii, segments=32):
        matrix = Matrix.Translation(center) @ Matrix.Diagonal((*radii, 1.0))
        verts = bmesh.ops.create_uvsphere(
            self.bm(mat), u_segments=segments, v_segments=segments // 2, radius=1.0, matrix=matrix
        )["verts"]
        for face in {face for vert in verts for face in vert.link_faces}:
            face.smooth = True

    def finish(self, collection):
        for name, (bm, mat) in self.meshes.items():
            mesh = bpy.data.meshes.new(f"{self.prefix}-{name}")
            bm.to_mesh(mesh)
            bm.free()
            mesh.materials.append(mat)
            link(bpy.data.objects.new(mesh.name, mesh), collection)


def link(obj, collection):
    collection.objects.link(obj)
    return obj


def mesh_object(name, bm, mat, collection):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    mesh.materials.append(mat)
    return link(bpy.data.objects.new(name, mesh), collection)


def rounded_rect(x0, x1, half_width, back_radius, front_radius, samples=12):
    corners = (
        (x1 - front_radius, -half_width + front_radius, front_radius, -90),
        (x1 - front_radius, half_width - front_radius, front_radius, 0),
        (x0 + back_radius, half_width - back_radius, back_radius, 90),
        (x0 + back_radius, -half_width + back_radius, back_radius, 180),
    )
    points = []
    for cx, cy, radius, start in corners:
        for i in range(samples + 1):
            angle = math.radians(start + 90 * i / samples)
            point = (cx + radius * math.cos(angle), cy + radius * math.sin(angle))
            if not points or (Vector(point) - Vector(points[-1])).length > 1e-4:
                points.append(point)
    return points




def prism(name, outline, z0, z1, bevel, mat, collection):
    """Extrude a closed XY outline between z0 and z1 with rounded edges."""
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "2D"
    curve.fill_mode = "BOTH"
    curve.extrude = max((z1 - z0) / 2 - bevel, 0.001)
    curve.bevel_depth = bevel
    curve.bevel_resolution = 3
    spline = curve.splines.new("POLY")
    spline.points.add(len(outline) - 1)
    for point, (x, y) in zip(spline.points, outline):
        point.co = (x, y, 0.0, 1.0)
    spline.use_cyclic_u = True
    spline.use_smooth = True
    curve.materials.append(mat)
    obj = link(bpy.data.objects.new(name, curve), collection)
    obj.location.z = (z0 + z1) / 2
    return obj


def tube(name, points, radius, mat, collection, cyclic=False):
    curve = bpy.data.curves.new(name, "CURVE")
    curve.dimensions = "3D"
    curve.bevel_depth = radius
    curve.bevel_resolution = 3
    spline = curve.splines.new("POLY")
    spline.points.add(len(points) - 1)
    for point, co in zip(spline.points, points):
        point.co = (*co, 1.0)
    spline.use_cyclic_u = cyclic
    spline.use_smooth = True
    curve.materials.append(mat)
    return link(bpy.data.objects.new(name, curve), collection)




# Hull -------------------------------------------------------------------------------------------

def hull_half_width(t):
    """Plump plan view: a rounded stern and a round, blunt bow."""
    width = BEAM / 2
    if t < 0.12:
        u = (0.12 - t) / 0.12
        width *= 0.72 + 0.28 * math.sqrt(1 - u ** 2)
    if t > 0.55:
        u = (t - 0.55) / 0.45
        width *= max(1 - u ** 2, 0.0) ** 0.55
    return max(width, 0.03)


def deck_z(t):
    return 1.05 + 0.4 * max(0.0, (t - 0.45) / 0.55) ** 2


def keel_z(t):
    return -0.6 + 0.7 * max(0.0, (t - 0.65) / 0.35) ** 1.6 + 0.2 * max(0.0, (0.1 - t) / 0.1)


def section(t, samples=28):
    """Boxy superellipse cross-section from the port deck edge, under the keel, to the starboard deck edge."""
    width, top, bottom = hull_half_width(t), deck_z(t), keel_z(t)
    points = []
    for j in range(samples + 1):
        theta = math.pi + math.pi * j / samples
        c, s = math.cos(theta), math.sin(theta)
        y = width * math.copysign(abs(c) ** 0.4, c)
        z = top + (top - bottom) * math.copysign(abs(s) ** 0.4, s)
        y *= 0.88 + 0.12 * (z - bottom) / (top - bottom)
        points.append((y, z))
    return points


def x_of(t):
    return -LENGTH / 2 + t * LENGTH


def t_of(x):
    return (x + LENGTH / 2) / LENGTH


def side_y(t, z):
    """Half-width of the hull surface at height z."""
    points = [p for p in section(t, 400) if p[0] >= 0]
    return min(points, key=lambda p: abs(p[1] - z))[0]


def build_hull(collection, mats):
    steps = 80
    bm = bmesh.new()
    rows = []
    for i in range(steps + 1):
        t = i / steps
        rows.append([bm.verts.new((x_of(t), y, z)) for y, z in section(t)])
    for i in range(steps):
        for j in range(len(rows[0]) - 1):
            face = bm.faces.new((rows[i][j], rows[i + 1][j], rows[i + 1][j + 1], rows[i][j + 1]))
            face.smooth = True
    for t in (0.0, 1.0):
        bm.faces.new([bm.verts.new((x_of(t), y, z)) for y, z in section(t)])
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    mesh_object("hull", bm, mats["hull"], collection)

    deck = bmesh.new()
    pairs = []
    for i in range(steps + 1):
        t = i / steps
        width, z = hull_half_width(t) * 0.99, deck_z(t) - 0.06
        pairs.append((deck.verts.new((x_of(t), -width, z)), deck.verts.new((x_of(t), width, z))))
    for (a, b), (c, d) in zip(pairs, pairs[1:]):
        deck.faces.new((a, c, d, b))
    mesh_object("deck", deck, mats["deck"], collection)

    edge = [(x_of(i / steps), hull_half_width(i / steps), deck_z(i / steps)) for i in range(steps + 1)]
    edge += [(x, -y, z) for x, y, z in reversed(edge)]
    tube("rub-rail", edge, 0.08, mats["white"], collection, cyclic=True)

    waterline = [(x_of(i / steps), side_y(i / steps, 0.0) + 0.05, 0.0) for i in range(steps + 1)]
    waterline += [(x, -y, z) for x, y, z in reversed(waterline)]
    foam = tube("foam", waterline, 0.12, mats["foam"], collection, cyclic=True)
    foam.scale.z = 0.35


# Ferry ------------------------------------------------------------------------------------------

DECKS = (
    # name, x0, x1, half width, back radius, front radius, z0, z1, window band
    ("deck", -3.05, 0.55, 1.5, 0.7, 1.2, 0.97, 1.95, (1.36, 1.66)),
    ("bridge", -2.1, 0.15, 1.2, 0.55, 0.95, 1.95, 2.85, (2.22, 2.6)),
)
PORTHOLES = (-2.3, -1.55, -0.8, -0.05)


def build_superstructure(collection, mats):
    for name, x0, x1, half, rb, rf, z0, z1, (b0, b1) in DECKS:
        prism(name, rounded_rect(x0, x1, half, rb, rf), z0, z1, 0.06, mats["white"], collection)
        grow = 0.06  # clears the wall's bevel, which widens its outline
        prism(f"{name}-windows", rounded_rect(x0 - grow, x1 + grow, half + grow, rb + grow, rf + grow),
              b0, b1, 0.01, mats["glass"], collection)
    prism("bridge-roof", rounded_rect(-2.25, 0.32, 1.34, 0.65, 1.05), 2.85, 3.03, 0.08, mats["roof"], collection)


def build_portholes(parts, mats, z=0.55):
    for x in PORTHOLES:
        y = side_y(t_of(x), z)
        for side in (-1, 1):
            parts.cylinder(mats["white"], (x, side * (y - 0.05), z), (0, side, 0), 0.24, 0.1)
            parts.cylinder(mats["glass"], (x, side * (y - 0.03), z), (0, side, 0), 0.16, 0.1)


def build_funnel(collection):
    bm = bmesh.new()
    bmesh.ops.create_cone(bm, cap_ends=True, segments=48, radius1=0.46, radius2=0.54, depth=1.8,
                          matrix=Matrix.Translation((0, 0, 0.9)))
    for vert in bm.verts:
        vert.co.y *= 0.8
        vert.co.x -= 0.18 * vert.co.z
    for face in bm.faces:
        face.normal_update()
        face.smooth = abs(face.normal.z) < 0.7
    funnel_material = banded_material("funnel", 0.0, 1.8, [
        (0.0, PALETTE["yellow"]), (1.05, PALETTE["hull"]), (1.3, PALETTE["yellow"]), (1.58, PALETTE["black"]),
    ])
    funnel = mesh_object("funnel", bm, funnel_material, collection)
    bevel = funnel.modifiers.new("bevel", "BEVEL")
    bevel.width, bevel.segments, bevel.limit_method = 0.05, 3, "ANGLE"
    funnel.location = (-2.55, 0.0, 1.9)


def build_containers(collection, mats):
    length, width, height = 1.0, 0.68, 0.62
    slots = [(1.45, -0.36, 0), (1.45, 0.36, 0), (1.45, 0.0, 1)]
    for index, (x, y, tier) in enumerate(slots):
        base = deck_z(t_of(x - length / 2)) - 0.06 + tier * height
        outline = rounded_rect(x - length / 2 + 0.03, x + length / 2 - 0.03, width / 2 - 0.03, 0.1, 0.1)
        outline = [(px, py + y) for px, py in outline]
        prism(f"container-{index}", outline, base, base + height - 0.02, 0.07, mats[f"container-{index}"], collection)


def build_ferry(collection):
    mats = {
        "hull": banded_material("hull", -0.7, 1.4, [
            (-0.7, PALETTE["boot"]), (-0.02, PALETTE["white"]), (0.08, PALETTE["hull"]),
        ]),
        "white": material("white", PALETTE["white"], 0.3, 0.6),
        "roof": material("roof", PALETTE["hull"], 0.35, 0.3),
        "deck": material("deck", PALETTE["deck"], 0.6, 0.1),
        "glass": material("glass", PALETTE["glass"], 0.12, 0.8),
        "foam": material("foam", PALETTE["foam"], 0.7, 0.0),
    }
    for index, color in enumerate(CONTAINER_COLORS):
        mats[f"container-{index}"] = material(f"container-{index}", color, 0.38, 0.4)

    parts = Parts("ferry")
    build_hull(collection, mats)
    build_superstructure(collection, mats)
    build_funnel(collection)
    build_portholes(parts, mats)
    build_containers(collection, mats)
    parts.finish(collection)


# Scene ------------------------------------------------------------------------------------------

def build_sea(collection):
    obj = link(bpy.data.objects.new("ocean", bpy.data.meshes.new("ocean")), collection)
    ocean = obj.modifiers.new("ocean", "OCEAN")
    ocean.geometry_mode = "GENERATE"
    ocean.resolution = 11
    ocean.spatial_size = 40
    ocean.repeat_x = ocean.repeat_y = 4
    ocean.wave_scale = 0.12
    ocean.wind_velocity = 9.0
    ocean.choppiness = 1.1
    ocean.wave_alignment = 0.3
    ocean.random_seed = 7
    ocean.use_foam = True
    ocean.foam_layer_name = "foam"
    ocean.foam_coverage = 0.25
    obj.location = (-80.0, -80.0, 0.0)
    obj.data.materials.append(sea_material())
    return obj


def build_world(name, top, horizon, strength):
    world = bpy.data.worlds.new(name)
    world.use_nodes = True
    nodes, links = world.node_tree.nodes, world.node_tree.links
    coords = nodes.new("ShaderNodeTexCoord")
    separate = nodes.new("ShaderNodeSeparateXYZ")
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (*linear(horizon), 1.0)
    ramp.color_ramp.elements[1].color = (*linear(top), 1.0)
    ramp.color_ramp.elements[1].position = 0.6
    links.new(coords.outputs["Generated"], separate.inputs["Vector"])
    links.new(separate.outputs["Z"], ramp.inputs["Fac"])
    links.new(ramp.outputs["Color"], nodes["Background"].inputs["Color"])
    nodes["Background"].inputs["Strength"].default_value = strength
    return world


def build_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    collections = {}
    for name in ("Ferry", "Sea", "Studio"):
        collections[name] = bpy.data.collections.new(name)
        scene.collection.children.link(collections[name])

    build_ferry(collections["Ferry"])
    build_sea(collections["Sea"])

    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=1, y_segments=1, size=60)
    floor = mesh_object("floor", bm, material("floor", "#A7ABB2", 0.8, 0.0), collections["Studio"])
    floor.location.z = -0.6

    scene.world = build_world("sky", "#3C8BEA", "#D8ECFF", 1.0)

    sun = bpy.data.lights.new("sun", "SUN")
    sun.energy = 3.2
    sun.angle = math.radians(4)
    sun_obj = link(bpy.data.objects.new("sun", sun), scene.collection)
    sun_obj.rotation_euler = Vector((-0.35, 0.75, 1.0)).to_track_quat("Z", "Y").to_euler()

    camera = link(bpy.data.objects.new("camera", bpy.data.cameras.new("camera")), scene.collection)
    camera.data.lens = 60
    distance, azimuth, elevation = 16.0, math.radians(46), math.radians(22)
    camera.location = (
        distance * math.cos(elevation) * math.cos(azimuth),
        distance * math.cos(elevation) * math.sin(azimuth),
        distance * math.sin(elevation) + 1.0,
    )
    camera.rotation_euler = (Vector((-0.1, 0.0, 1.15)) - camera.location).to_track_quat("-Z", "Y").to_euler()
    scene.camera = camera

    scene.render.engine = "CYCLES"
    scene.cycles.use_denoising = True
    scene.view_settings.view_transform = "Standard"

    ferry_layer = scene.view_layers[0]
    ferry_layer.name = "Ferry"
    sea_layer = scene.view_layers.new("Sea")
    for layer in (ferry_layer, sea_layer):
        layer.layer_collection.children["Studio"].exclude = True
    sea_layer.layer_collection.children["Ferry"].exclude = True
    return scene


def use_gpu(scene):
    prefs = bpy.context.preferences.addons["cycles"].preferences
    try:
        prefs.compute_device_type = "METAL"
    except TypeError as error:
        print(f"Metal unavailable, rendering on CPU: {error}")
        return
    prefs.get_devices()
    for device in prefs.devices:
        device.use = True
        print(f"Cycles device: {device.name} ({device.type})")
    scene.cycles.device = "GPU"


def render_layer(scene, layer_name, path, transparent):
    # In the ferry layer the ocean only catches the ferry's shadow and hides the hull below the waterline.
    bpy.data.objects["ocean"].is_shadow_catcher = layer_name == "Ferry"
    for layer in scene.view_layers:
        layer.use = layer.name == layer_name
    scene.render.film_transparent = transparent
    scene.render.filepath = path
    bpy.ops.render.render(write_still=True)


def render_showcase(scene, path, preview):
    layer = scene.view_layers["Ferry"]
    layer.layer_collection.children["Sea"].exclude = True
    layer.layer_collection.children["Studio"].exclude = False
    bpy.data.objects["foam"].hide_render = True
    scene.world = build_world("studio", "#B4B8BF", "#A7ABB2", 1.2)
    scene.render.resolution_x, scene.render.resolution_y = (800, 600) if preview else (1600, 1200)
    render_layer(scene, "Ferry", path, False)


def main():
    args = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    preview = "--preview" in args
    scene = build_scene()
    use_gpu(scene)
    scene.cycles.samples = 24 if preview else 128
    scene.render.resolution_x = scene.render.resolution_y = 512 if preview else 1024
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT_DIR, "FerryIcon.blend"))
    suffix, icon_dir = ("-preview", OUT_DIR) if preview else ("", ASSETS)
    if "--render" in args:
        render_layer(scene, "Sea", os.path.join(icon_dir, f"sea{suffix}.png"), False)
        render_layer(scene, "Ferry", os.path.join(icon_dir, f"ferry{suffix}.png"), True)
    if "--render" in args or "--showcase" in args:
        render_showcase(scene, os.path.join(OUT_DIR, f"FerryModel{suffix}.png"), preview)


main()
