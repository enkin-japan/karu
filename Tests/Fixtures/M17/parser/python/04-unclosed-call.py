import math

SCALE = 2.5


class Geometry:
    def __init__(self, radius):
        self.radius = radius

    def area(self):
        return math.pi * self.radius ** 2

    def scaled_area(self, factor, precision=2):
        value = round(self.area() * factor, ‸
        return value


def unit_circle():
    return Geometry(1)
