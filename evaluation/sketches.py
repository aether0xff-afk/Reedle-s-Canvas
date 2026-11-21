"""Deterministic synthetic ink for the tutor benchmark."""

from collections.abc import Callable
from functools import lru_cache
from io import BytesIO
from math import atan2, ceil, cos, dist, pi, sin
from random import Random
from typing import TypeAlias

from PIL import Image, ImageDraw, ImageFont


Point: TypeAlias = tuple[float, float]
Box: TypeAlias = tuple[float, float, float, float]
Arm: TypeAlias = tuple[str, int, int]  # atom, order, lone electron pairs
SIZE = (520, 300)


@lru_cache(maxsize=16)
def _font(size: int) -> ImageFont.FreeTypeFont:
    return ImageFont.load_default(size)


class Pen:
    def __init__(self, image: Image.Image, rng: Random):
        self.image = image
        self.draw = ImageDraw.Draw(image)
        self.rng = rng
        self.ink = (23, 41, 69, 255)

    def text(self, position: Point, text: str, size: int = 25, *, centered: bool = False) -> None:
        font = _font(size)
        x, y = position
        if centered:
            x -= font.getlength(text) / 2
        slope = self.rng.uniform(-0.045, 0.045)
        since_start = 0.0
        for character in text:
            left, top, right, bottom = font.getbbox(character)
            advance = font.getlength(character) + self.rng.uniform(0.2, 1.7)
            if right > left and bottom > top and character.strip():
                mask = Image.new("L", (right - left + 8, bottom - top + 8))
                ImageDraw.Draw(mask).text((4 - left, 4 - top), character, fill=255, font=font)
                mask = mask.rotate(self.rng.uniform(-8, 8), Image.Resampling.BICUBIC)
                baseline = since_start * slope + self.rng.uniform(-2.2, 2.2)
                self.image.paste(self.ink, (round(x + left - 4), round(y + top - 4 + baseline)), mask)
            x += advance
            since_start += advance

    def line(self, *points: Point, width: int = 3) -> None:
        wobbled = [points[0]]
        for first, second in zip(points, points[1:]):
            segments = max(1, ceil(dist(first, second) / 15))
            for index in range(1, segments):
                fraction = index / segments
                wobbled.append(tuple(
                    start + (end - start) * fraction + self.rng.uniform(-1.2, 1.2)
                    for start, end in zip(first, second)
                ))
            wobbled.append(second)
        self.draw.line(wobbled, fill=self.ink, width=width, joint="curve")

    def dot(self, point: Point, radius: float = 1.9) -> None:
        x, y = point
        self.draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=self.ink)

    def arrow(self, start: Point, end: Point, *, width: int = 3) -> None:
        x, y = end
        angle = atan2(y - start[1], x - start[0])
        self.line(start, end, width=width)
        head = tuple((x - 13 * cos(angle + offset), y - 13 * sin(angle + offset)) for offset in (-0.58, 0.58))
        self.line(head[0], end, head[1], width=width)

    def oval(self, center: Point, radii: Point) -> None:
        points = tuple(
            (center[0] + radii[0] * cos(index * pi / 12), center[1] + radii[1] * sin(index * pi / 12))
            for index in range(24)
        )
        self.line(*points, points[0])


Sketch: TypeAlias = tuple[Callable[[Pen], None], ...]


def render(sketch: Sketch, seed: str) -> tuple[bytes, tuple[Box, ...]]:
    rng = Random(seed)
    width, height = SIZE
    paper = Image.new("RGBA", SIZE, (252, 251, 247, 255))
    ruler = ImageDraw.Draw(paper)
    for y in range(56, height, 28):
        ruler.line((0, y, width, y), fill=(230, 235, 238, 255))
    boxes = []
    for group in sketch:
        layer = Image.new("RGBA", SIZE)
        group(Pen(layer, rng))
        left, top, right, bottom = layer.getbbox()
        left, top = max(0, left - 5), max(0, top - 5)
        right, bottom = min(width, right + 5), min(height, bottom + 5)
        boxes.append((left / width, top / height, (right - left) / width, (bottom - top) / height))
        paper.alpha_composite(layer)
    output = BytesIO()
    paper.convert("RGB").save(output, format="PNG")
    return output.getvalue(), tuple(boxes)


def _with_context(context: str, diagram: Callable[[Pen], None]) -> Sketch:
    return (lambda pen: pen.text((31, 18), context, 24), diagram)


def equation(context: str, work: str) -> Sketch:
    return _with_context(context, lambda pen: pen.text((58, 117), work, 44))


DIRECTIONS = ((-1, 0), (1, 0), (0, -1), (0, 1))
ARM_DIRECTIONS = ((), ((1, 0),), ((-1, 0), (1, 0)), ((-1, 0), (1, 0), (0, 1)), DIRECTIONS)


def _atom(pen: Pen, point: Point, symbol: str, lone_pairs: int, bonds: tuple[Point, ...]) -> None:
    x, y = point
    pen.text((x, y - 22), symbol, 31, centered=True)
    free = [direction for direction in DIRECTIONS if direction not in bonds]
    for dx, dy in free[:lone_pairs]:
        for gap in (-4, 4):
            pen.dot((x + dx * 22 + dy * gap, y + dy * 22 - dx * gap))


def lewis(formula: str, center: str, center_pairs: int, arms: tuple[Arm, ...], *, charge: str = "") -> Sketch:
    def draw(pen: Pen) -> None:
        directions = ARM_DIRECTIONS[len(arms)]
        cx, cy = (203, 166) if len(arms) == 1 else (260, 166)
        _atom(pen, (cx, cy), center, center_pairs, directions)
        for (symbol, order, pairs), (dx, dy) in zip(arms, directions):
            arm_distance = 84 if dy else 112
            x, y = cx + dx * arm_distance, cy + dy * arm_distance
            _atom(pen, (x, y), symbol, pairs, ((-dx, -dy),))
            for index in range(order):
                offset = (index - (order - 1) / 2) * 6
                pen.line((cx + dx * 23 + dy * offset, cy + dy * 23 - dx * offset),
                         (x - dx * 23 + dy * offset, y - dy * 23 - dx * offset))
        if charge:
            pen.line((134, 76), (117, 76), (117, 278), (134, 278))
            pen.line((397, 76), (414, 76), (414, 278), (397, 278))
            pen.text((426, 55), charge, 31)

    return _with_context(formula, draw)


FORCE_VECTORS = {
    "up": ((252, 147), (252, 83), (267, 73)),
    "down": ((252, 190), (252, 254), (268, 236)),
    "left": ((218, 166), (132, 166), (132, 136)),
    "right": ((286, 166), (372, 166), (340, 136)),
}


def forces(context: str, *arrows: tuple[str, str]) -> Sketch:
    def draw(pen: Pen) -> None:
        pen.line((218, 147), (286, 147), (286, 190), (218, 190), (218, 147))
        for direction, label in arrows:
            start, end, position = FORCE_VECTORS[direction]
            pen.arrow(start, end)
            pen.text(position, label)

    return _with_context(context, draw)


GRAPH_LINES = {
    "level": ((143, 159), (369, 159)),
    "rising": ((143, 218), (369, 101)),
    "falling": ((143, 101), (369, 218)),
}


def graph(context: str, trend: str | None) -> Sketch:
    def draw(pen: Pen) -> None:
        pen.arrow((120, 243), (120, 78))
        pen.arrow((120, 243), (405, 243))
        pen.text((90, 73), "v")
        pen.text((415, 226), "t")
        if trend is not None:
            pen.line(*GRAPH_LINES[trend], width=4)

    return _with_context(context, draw)


def circuit(context: str, switch: str) -> Sketch:
    def draw(pen: Pen) -> None:
        pen.line((245, 222), (139, 222), (139, 109), (178, 109))
        pen.line((209, 109), (274, 109))
        pen.line((330, 109), (384, 109), (384, 222), (264, 222))
        pen.line((245, 195), (245, 249))
        pen.line((264, 207), (264, 237))
        pen.oval((302, 109), (28, 28))
        pen.line((286, 93), (319, 125))
        pen.line((286, 125), (319, 93))
        pen.dot((178, 109), 4)
        pen.dot((209, 109), 4)
        if switch == "closed":
            pen.line((178, 109), (209, 109))
        elif switch == "open":
            pen.line((178, 109), (207, 88))

    return _with_context(context, draw)


def reflection(context: str, reflected: int | None) -> Sketch:
    def draw(pen: Pen) -> None:
        pen.line((351, 73), (351, 267))
        for y in range(80, 265, 17):
            pen.line((353, y), (365, y + 8), width=2)
        for x in range(119, 347, 13):
            pen.line((x, 169), (x + 6, 169), width=2)
        pen.arrow((205, 85), (351, 169))
        pen.text((183, 130), "30 deg", 21)
        if reflected is not None:
            pen.arrow((351, 169), (205, 253) if reflected == 30 else (295, 266))
            pen.text((195, 180), f"{reflected} deg", 21)

    return _with_context(context, draw)
