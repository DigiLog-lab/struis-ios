"""Native PNG and vector PDF drawing. Coordinates start at the top left."""
import json
import math
import os
from _hyotan_graphics import render


class Canvas:
    def __init__(self, width=640, height=480):
        self.width, self.height = width, height
        self.commands = []

    def line(self, points, color=(0, 0, 0), width=1):
        self.commands.append(dict(type="polyline", points=list(points), color=color, line_width=width))

    def rect(self, x, y, width, height, color=(0, 0, 0), fill=False):
        self.commands.append(dict(type="rect", x=x, y=y, width=width, height=height, color=color, fill=fill))

    def ellipse(self, x, y, width, height, color=(0, 0, 0), fill=False):
        self.commands.append(dict(type="ellipse", x=x, y=y, width=width, height=height, color=color, fill=fill))

    def text(self, x, y, text, size=12, color=(0, 0, 0)):
        self.commands.append(dict(type="text", x=x, y=y, text=str(text), size=size, color=color))

    def image(self, path, x, y, width, height):
        self.commands.append(dict(type="image", path=os.path.abspath(path), x=x, y=y, width=width, height=height))

    def save(self, path):
        render(json.dumps(dict(width=self.width, height=self.height, commands=self.commands), allow_nan=False), os.fspath(path))


def plot(x, y, path, title="", width=640, height=480):
    x, y = list(x), list(y)
    if len(x) != len(y) or len(x) < 2 or not all(math.isfinite(v) for v in x + y):
        raise ValueError("x and y must contain matching finite values (at least two)")
    if width < 200 or height < 160:
        raise ValueError("Plot dimensions must be at least 200 by 160")
    xmin, xmax, ymin, ymax = min(x), max(x), min(y), max(y)
    if xmin == xmax: xmin, xmax = xmin - 0.5, xmax + 0.5
    if ymin == ymax: ymin, ymax = ymin - 0.5, ymax + 0.5
    c = Canvas(width, height)
    c.rect(0, 0, width, height, (1, 1, 1), fill=True)
    left, right, top, bottom = 64, width - 24, 48, height - 40
    for step in range(6):
        fraction = step / 5
        px, py = left + fraction * (right - left), bottom - fraction * (bottom - top)
        c.line([(left, py), (right, py)], (0.88, 0.88, 0.88))
        c.text(5, py - 7, f"{ymin + fraction * (ymax-ymin):.3g}", 11)
        c.text(px - 12, bottom + 10, f"{xmin + fraction * (xmax-xmin):.3g}", 11)
    c.line([(left, top), (left, bottom), (right, bottom)])
    c.line([(left + (a-xmin)/(xmax-xmin)*(right-left), bottom - (b-ymin)/(ymax-ymin)*(bottom-top)) for a,b in zip(x,y)], (0.1, 0.4, 0.8), 2)
    c.text(left, 12, title, 20)
    c.save(path)
