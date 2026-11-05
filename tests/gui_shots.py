#!/usr/bin/env python3
"""Снимки всех вкладок окна в PNG, без нажатий на кнопки: gui_shots.py ПАПКА [префикс]
Запускать через Broadway или любой другой дисплей с GSK_RENDERER=cairo."""
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
sys.path.insert(0, os.path.join(REPO, "gui"))
os.environ.setdefault("ZAPRET_GUI_NON_UNIQUE", "1")

import main as app  # noqa: E402
from gi.repository import GLib, Gtk  # noqa: E402

out, prefix = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else ""


def snapshot(window, path):
    paintable = Gtk.WidgetPaintable.new(window)
    snap = Gtk.Snapshot()
    paintable.snapshot(snap, window.get_width(), window.get_height())
    node = snap.to_node()
    if node is None:
        return False
    texture = window.get_native().get_renderer().render_texture(node, None)
    texture.save_to_png(path)
    return True


application = app.Application()


def steps():
    window = application.window
    pages = ["home", "strategies", "sites", "settings", "diagnostics"]
    yield 2500
    for name in pages:
        window.show_page(name)
        yield 500
        # пока идёт анимация смены вкладки, снимка может не получиться
        while not snapshot(window, os.path.join(out, f"{prefix}{name}.png")):
            yield 200
    application.quit()


def start(_app):
    iterator = steps()

    def tick():
        try:
            GLib.timeout_add(next(iterator), tick)
        except StopIteration:
            pass
        return False

    GLib.timeout_add(100, tick)


application.connect("activate", start)
application.run([])
