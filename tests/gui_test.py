#!/usr/bin/env python3
"""Сценарий для окна приложения: нажимает те же кнопки, что и человек, и сверяет результат с утилитой.
Запускается через tests/gui-test.sh: снаружи окружения sandbox-test.sh он изменил бы настоящую систему."""
import glob
import os
import sys
import traceback

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
if not os.environ.get("ZAPRET_HOME"):
    sys.exit("Запускайте через tests/gui-test.sh")
sys.path.insert(0, os.path.join(REPO, "gui"))

# окно не должно подменять себя новой версией посреди проверки, даже если обновление вдруг найдётся
os.environ["ZAPRET_GUI_NO_EXEC"] = "1"

import main as app  # noqa: E402
from gi.repository import Adw, GLib, Gtk  # noqa: E402

OUT = sys.argv[1]
TIMEOUT_EXIT = 900
HOME_DIR = os.environ["ZAPRET_HOME"]
passed = 0
failed = 0
application = app.Application()


def check(title, condition):
    global passed, failed
    if condition:
        passed += 1
        print(f"  ok    {title}", flush=True)
    else:
        failed += 1
        print(f"  FAIL  {title}", flush=True)


class Until:
    """Шаг сценария ждёт условие, не останавливая окно."""

    def __init__(self, condition, seconds=60, title=""):
        self.condition = condition
        self.left = int(seconds * 10)
        self.title = title


def idle(window, seconds=120):
    return Until(lambda: window.job is None, seconds, "команда закончилась")


def dialog_open(window):
    return getattr(window, "last_dialog", None) is not None


def answer(window, response):
    dialog = window.last_dialog
    window.last_dialog = None
    dialog.emit("response", response)
    if hasattr(dialog, "force_close"):
        dialog.force_close()
    else:
        dialog.close()


def shot(window, name):
    """Снимок окна. Пока идёт смена вкладки, снимка может не быть, поэтому несколько попыток."""
    path = os.path.join(OUT, name + ".png")
    for _ in range(30):
        paintable = Gtk.WidgetPaintable.new(window)
        snap = Gtk.Snapshot()
        paintable.snapshot(snap, window.get_width(), window.get_height())
        node = snap.to_node()
        if node is not None:
            window.get_native().get_renderer().render_texture(node, None).save_to_png(path)
            return
        yield 0.2


def state(window):
    return window.backend.state()


def file_text(*parts):
    try:
        with open(os.path.join(HOME_DIR, *parts), encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return ""


def scenario():
    window = application.window
    style = Adw.StyleManager.get_default()
    style.set_color_scheme(Adw.ColorScheme.FORCE_DARK)
    yield Until(lambda: window.state.get("version") and window.strategies.rows and window.sites.rows, 20, "окно загрузило данные")
    yield 0.5

    print("Первый запуск", flush=True)
    check("обход выключен", not window.state.running)
    expected = len(glob.glob(os.path.join(HOME_DIR, "strategies", "*.conf")))
    check(f"в списке все стратегии: {expected}", expected > 0 and len(window.strategies.rows) == expected)
    yield from shot(window, "01-home-off-dark")
    window.home.power.emit("clicked")
    yield Until(lambda: dialog_open(window), 5)
    check("без стратегии кнопка предлагает выбор", dialog_open(window))
    yield 0.4
    yield from shot(window, "02-first-run-dialog")
    answer(window, "general")
    yield 0.2
    yield idle(window)
    yield Until(lambda: window.state.running, 8)
    check("general включается", state(window).running and state(window).get("running_strategy") == "general")
    check("кнопка показывает, что обход работает", window.home.hero.has_css_class("hero-on"))
    yield 0.4
    yield from shot(window, "03-home-on-dark")
    style.set_color_scheme(Adw.ColorScheme.FORCE_LIGHT)
    yield 0.4
    yield from shot(window, "04-home-on-light")

    print("Смена и выключение", flush=True)
    window.home.on_next()
    yield 0.2
    yield idle(window)
    check("следующая стратегия переключается", state(window).get("running_strategy") not in ("", "general"))
    window.home.power.emit("clicked")
    yield 0.2
    yield idle(window)
    yield Until(lambda: not window.state.running, 8)
    check("кнопка выключает обход", not state(window).running)
    check("главная показывает выключенное состояние", window.home.hero.has_css_class("hero-off"))

    print("Проверка выбранных стратегий: сайты и замирание", flush=True)
    window.show_page("strategies")
    page = window.strategies
    check("по умолчанию проверяются и сайты, и замирание", page.kind.get_selected() == 0)
    page.scope.set_selected(1)
    chosen = [name for name in page.names if name in ("general", "general (ALT5)")]
    check("обе стратегии есть в списке", len(chosen) == 2)
    for name in chosen:
        page.rows[name].pick.set_active(True)
    yield 0.3
    page.start.emit("clicked")
    yield Until(lambda: page.running_label.get_label().startswith("Стратегия"), 30)
    check("идёт прогресс", page.running_label.get_label().startswith("Стратегия"))
    yield from shot(window, "05-test-running")
    yield idle(window, 180)
    check("есть результаты по двум стратегиям", len(page.run_results) == 2)
    # 5 чисел проверки сайтов и 4 числа проверки замирания
    check("у каждой стратегии оба теста", all(len(values) == 9 for values in page.run_results.values()))
    check("лучшая стратегия определена", bool(page.best))
    check("карточка результата показана", page.best_group.get_visible())
    subtitle = page.best_row.get_subtitle()
    check("в карточке обе части отдельно и без оценки", subtitle.startswith("Сайты ") and "замирание" in subtitle
          and "Оценка" not in subtitle and "/" in subtitle)
    check("ошибочного диалога нет", not dialog_open(window))
    yield Until(lambda: all(page.by_name.get(name) and page.by_name[name].sites_tested and page.by_name[name].dpi_tested
                            for name in chosen), 10, "сохранённые результаты обоих тестов")
    yield 0.5
    check("у строк два отдельных результата", all(
        page.rows[name].sites_badge.get_label().startswith("сайты ") and "/" in page.rows[name].sites_badge.get_label()
        and page.rows[name].freeze_badge.get_label().startswith("замирание ") and "/" in page.rows[name].freeze_badge.get_label()
        for name in chosen))
    check("непроверенные помечены прочерком", all(
        page.rows[name].sites_badge.get_label() == "сайты —" for name in page.rows if not page.by_name[name].tested))
    tested = [name for name in page.rows if page.by_name[name].tested]
    check("проверенные стратегии стоят первыми", list(page.rows)[:len(tested)] == tested)
    order = [(-(page.by_name[n].sites_share or 0), page.by_name[n].freeze_share or 0) for n in tested]
    check("сначала больше сайтов, при равенстве меньше замирания", order == sorted(order))
    yield from shot(window, "06-test-result")
    best = page.best
    page.best_button.emit("clicked")
    yield 0.2
    yield idle(window)
    check("лучшая стратегия включается кнопкой", state(window).get("running_strategy") == best)

    print("Остановка проверки", flush=True)
    page.scope.set_selected(0)
    yield 0.2
    page.start.emit("clicked")
    yield Until(lambda: page.running_label.get_label().startswith("Стратегия 2"), 90)
    check("дошла до второй стратегии", page.running_label.get_label().startswith("Стратегия 2"))
    window.cancel_test()
    yield idle(window, 90)
    yield 0.5
    after = state(window)
    check("после остановки прежний обход вернулся", after.running and after.get("running_strategy") == best)
    check("файл с номером процесса теста убран", not os.path.exists(os.path.join(os.environ["ZAPRET_RUN"], "test.pid")))
    check("карточка прогресса скрыта", not page.running_card.get_visible())

    print("Только замирание", flush=True)
    page.kind.set_selected(2)
    page.scope.set_selected(1)
    for name, row in page.rows.items():
        row.pick.set_active(name == chosen[0])
    yield 0.2
    page.start.emit("clicked")
    yield 0.5
    yield idle(window, 120)
    check("DPI-тест дал результат", chosen[0] in page.run_results and len(page.run_results[chosen[0]]) == 4)
    page.kind.set_selected(0)
    page.scope.set_selected(0)

    print("Автоподбор", flush=True)
    window.show_page("home")
    window.home.on_auto()
    yield 0.2
    yield idle(window, 200)
    check("автоподбор оставляет обход включённым", state(window).running)
    check("прогресс автоподбора скрыт", not window.home.progress_box.get_visible())

    print("Сайты", flush=True)
    window.show_page("sites")
    sites = window.sites
    before = len(sites.rows)
    sites.entry.set_text("https://WWW.Example.org:8443/страница?x=1 rutracker.example")
    sites.add_button.emit("clicked")
    yield 0.2
    yield idle(window)
    yield Until(lambda: "example.org" in sites.rows, 5)
    check("ссылка превращается в домен", "example.org" in sites.rows and "example.org" in file_text("lists", "list-general.txt"))
    check("поле ввода очищается", sites.entry.get_text() == "")
    check("список пополнился", len(sites.rows) == before + 2)
    sites.search.set_text("example.org")
    yield 0.6
    check("поиск оставляет подходящие строки", sum(row.get_visible() for row in sites.rows.values()) == 1)
    yield from shot(window, "07-sites")
    sites.search.set_text("")
    sites.entry.set_text("это не домен")
    sites.add_button.emit("clicked")
    yield 0.2
    yield idle(window)
    check("неверный ввод не добавляется и не теряется", len(sites.rows) == before + 2 and sites.entry.get_text() != "")
    sites.entry.set_text("")
    sites.on_remove("example.org")
    yield Until(lambda: dialog_open(window), 5)
    answer(window, "remove")
    yield 0.2
    yield idle(window)
    yield Until(lambda: "example.org" not in sites.rows, 5)
    check("домен убирается", "example.org" not in file_text("lists", "list-general.txt").split())
    sites.remove("rutracker.example")
    yield 0.2
    yield idle(window)

    print("Настройки", flush=True)
    window.show_page("settings")
    settings = window.settings
    yield Until(lambda: settings.fake_files, 5)
    settings.autostart.set_active(False)
    yield 0.2
    yield idle(window)
    check("автозапуск выключается", state(window).get("autostart") == "0")
    settings.autostart.set_active(True)
    yield 0.2
    yield idle(window)
    check("автозапуск включается", state(window).get("autostart") == "1")

    settings.game_mode.set_selected(2)
    yield 0.2
    yield idle(window)
    check("режим фильтра игр меняется", state(window).get("game_mode") == "tcp")
    check("обход работает после смены режима", state(window).running)
    settings.tcp_entry.set_text("1024-2000, 3000")
    settings.on_ports("tcp", settings.tcp_entry)
    yield 0.2
    yield idle(window)
    check("порты сохраняются", state(window).get("game_tcp") == "1024-2000,3000")
    settings.tcp_entry.set_text("abc")
    settings.on_ports("tcp", settings.tcp_entry)
    yield 0.2
    check("неверные порты не отправляются", window.job is None and state(window).get("game_tcp") == "1024-2000,3000")
    settings.game_mode.set_selected(0)
    yield 0.2
    yield idle(window)

    settings.ipset_mode.set_selected(2)
    yield 0.2
    yield idle(window)
    check("режим IPSet any", state(window).get("ipset") == "any")
    settings.ipset_mode.set_selected(0)
    yield 0.2
    yield idle(window)
    check("режим IPSet none", state(window).get("ipset") == "none")

    other = next(name for name in settings.fake_files if name.startswith("stun"))
    settings.fake_discord.set_selected(settings.fake_files.index(other))
    yield 0.2
    yield idle(window)
    yield 0.6
    check("активный фейк меняется", window.backend.fakes()[0]["discord"] == other)

    flag = os.path.join(HOME_DIR, "utils", "check_updates.enabled")
    was = os.path.exists(flag)
    settings.update_check.set_active(not was)
    yield 0.2
    yield idle(window)
    check("автопроверка обновлений переключается", os.path.exists(flag) != was)
    settings.update_check.set_active(was)
    yield 0.2
    yield idle(window)

    settings.shortcut.set_active(True)
    yield 0.3
    check("ярлык появляется на рабочем столе", os.path.exists(window.shortcut_path()) and os.access(window.shortcut_path(), os.X_OK))
    settings.shortcut.set_active(False)
    yield 0.3
    check("ярлык убирается", not os.path.exists(window.shortcut_path()))

    print("Обновление приложения без интернета", flush=True)
    check("баннера о новой версии нет", not window.notice_app.get_visible())
    window.last_toast = None
    window.show_page("home")
    window.home.update_button.emit("clicked")
    yield 0.2
    # две проверки подряд: стратегии Flowseal, затем само приложение
    yield Until(lambda: window.job is None and window.last_toast, 120, "проверка обновлений закончилась")
    told = bool(window.last_toast) or dialog_open(window)
    check("кнопка обновления честно сообщает, что не вышло", told)
    check("окно не перезапускалось и работает", not window.restarting and window.job is None)
    if dialog_open(window):
        answer(window, "ok")
    yield 0.3

    check("кнопка обновления стоит на главной", window.home.update_button.get_parent() is not None and window.home.version_row.get_title().startswith("Zapret Cap"))
    window.show_page("settings")
    window.show_about()
    yield 0.5
    about = getattr(window, "last_about", None)
    check("в окне «О приложении» нет безымянной ссылки", about is not None and not about.get_website())
    yield from shot(window, "10-about")
    if about is not None:
        about.force_close() if hasattr(about, "force_close") else about.close()
    yield 0.3
    settings.on_hosts()
    yield 0.2
    yield idle(window, 40)
    check("без сети про hosts честно сказано", dialog_open(window))
    if dialog_open(window):
        answer(window, "ok")
    yield 0.5
    yield from shot(window, "08-settings-light")

    print("Помощь", flush=True)
    window.show_page("diagnostics")
    help_page = window.diagnostics
    help_page.run_button.emit("clicked")
    yield 0.2
    yield idle(window, 60)
    check("диагностика показывает результат", len(help_page.result_rows) >= 5)
    yield 0.5
    yield from shot(window, "09-diagnostics-light")
    help_page.on_discord()
    yield Until(lambda: dialog_open(window), 5)
    answer(window, "clear")
    yield 0.2
    yield idle(window, 30)
    check("очистка кэша Discord не падает", window.job is None and not dialog_open(window))
    window.show_log()
    yield 0.5
    check("журнал действий ведётся", any("zapret diag" in line for line in window.log_lines))
    for toplevel in Gtk.Window.list_toplevels():
        if toplevel is not window and toplevel.get_title() == "Журнал действий":
            toplevel.close()

    print("Ошибка команды", flush=True)
    window.run_job(["use", "нет такой"], "Проверка ошибки…")
    yield 0.2
    yield idle(window, 20)
    check("ошибка команды показывается диалогом", dialog_open(window))
    if dialog_open(window):
        answer(window, "ok")
    window.show_page("home")
    yield 0.3

    print("Закрытие окна во время проверки", flush=True)
    style.set_color_scheme(Adw.ColorScheme.FORCE_DARK)
    page.scope.set_selected(0)
    page.start.emit("clicked")
    yield Until(lambda: page.running_label.get_label().startswith("Стратегия"), 30)
    check("окно не закрывается молча", window.on_close(window) is True and dialog_open(window))
    answer(window, "stop")
    yield idle(window, 90)
    check("после остановки обход на месте", state(window).running)
    yield 1


def main_loop():
    steps = scenario()
    deadline = {"left": TIMEOUT_EXIT * 10}
    pending = {"until": None}

    def finish(failure=None):
        global failed
        if failure:
            failed += 1
            print(f"  FAIL  {failure}", flush=True)
        application.quit()
        return False

    def tick():
        deadline["left"] -= 1
        if deadline["left"] <= 0:
            return finish("сценарий не уложился во время")
        until = pending["until"]
        if until is not None:
            if until.condition():
                pending["until"] = None
            else:
                until.left -= 1
                if until.left <= 0:
                    pending["until"] = None
                    check(f"дождались: {until.title or 'условие'}", False)
            return True
        try:
            step = next(steps)
        except StopIteration:
            return finish()
        except Exception:
            traceback.print_exc()
            return finish("сценарий упал")
        if isinstance(step, Until):
            pending["until"] = step
            return True
        GLib.timeout_add(int(step * 1000), resume)
        return False

    def resume():
        GLib.timeout_add(100, tick)
        return False

    GLib.timeout_add(100, tick)


application.connect("activate", lambda _: main_loop())
code = application.run([])
print(f"Итого пройдено: {passed}, ошибок: {failed}", flush=True)
sys.exit(1 if failed or passed == 0 else code)
