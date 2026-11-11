#!/usr/bin/env python3
"""Zapret Cap: окно приложения."""
import os
import re
import subprocess
import sys
import threading
import time

import gi

gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import backend as be  # noqa: E402

APP_ID = "org.zapretcap.ZapretCap"
HERE = os.path.dirname(os.path.realpath(__file__))
RELEASES_URL = "https://github.com/Flowseal/zapret-discord-youtube/releases/latest"
# в окне «О приложении» в этом порядке
LINKS = [
    ("Zapret Cap на GitHub", "https://github.com/CapptainnCWC/zapret-cap"),
    ("zapret2 от bol-van: движок обхода", "https://github.com/bol-van/zapret2"),
    ("Стратегии Flowseal (zapret-discord-youtube)", "https://github.com/Flowseal/zapret-discord-youtube"),
]
POLL_SECONDS = 4
PORTS_RE = re.compile(r"^\s*[0-9]+(-[0-9]+)?(\s*,\s*[0-9]+(-[0-9]+)?)*\s*$")

GAME_MODES = [("disabled", "Выключен"), ("all", "TCP и UDP"), ("tcp", "Только TCP"), ("udp", "Только UDP")]
IPSET_MODES = [
    ("none", "Никакие", "Обычный режим"),
    ("loaded", "Из списка", "Адреса из скачанного списка"),
    ("any", "Все", "Может помочь, если сайт не открывается, но сильнее нагружает компьютер"),
]


def dispatch(callback, *args):
    GLib.idle_add(lambda: callback(*args) and False)


def in_background(work, done):
    """work выполняется в потоке, done получает результат в главном потоке."""

    def runner():
        try:
            result = work()
        except (OSError, subprocess.SubprocessError):
            result = None
        dispatch(done, result)

    threading.Thread(target=runner, daemon=True).start()


def page_container():
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=24)
    box.set_margin_top(24)
    box.set_margin_bottom(32)
    box.set_margin_start(16)
    box.set_margin_end(16)
    clamp = Adw.Clamp(maximum_size=760, tightening_threshold=560)
    clamp.set_child(box)
    scrolled = Gtk.ScrolledWindow(hscrollbar_policy=Gtk.PolicyType.NEVER, vexpand=True)
    scrolled.set_child(clamp)
    return scrolled, box


def action_row(title, subtitle="", icon=None):
    row = Adw.ActionRow(title=GLib.markup_escape_text(title), subtitle=GLib.markup_escape_text(subtitle))
    if icon:
        row.add_prefix(Gtk.Image.new_from_icon_name(icon))
    return row


def link_row(title, subtitle, icon, callback):
    row = action_row(title, subtitle, icon)
    row.add_suffix(Gtk.Image.new_from_icon_name("go-next-symbolic"))
    row.set_activatable(True)
    row.connect("activated", lambda _: callback())
    return row


def badge(text, kind="badge-neutral"):
    label = Gtk.Label(label=text, valign=Gtk.Align.CENTER)
    label.add_css_class("badge")
    label.add_css_class(kind)
    return label


def centered_button(label, css=None):
    button = Gtk.Button(label=label, valign=Gtk.Align.CENTER)
    if css:
        button.add_css_class(css)
    return button


def pill_button(label, css="suggested-action"):
    button = Gtk.Button(label=label, halign=Gtk.Align.CENTER)
    button.add_css_class("pill")
    button.add_css_class(css)
    return button


class HomePage:
    def __init__(self, win):
        self.win = win
        self.widget, box = page_container()

        self.hero = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.hero.add_css_class("hero")
        self.hero.add_css_class("hero-off")

        self.power = Gtk.Button(halign=Gtk.Align.CENTER)
        self.power.add_css_class("power")
        self.power.set_tooltip_text("Включить или выключить обход")
        icon = Gtk.Image.new_from_icon_name("system-shutdown-symbolic")
        icon.set_pixel_size(44)
        self.power.set_child(icon)
        self.power.set_margin_bottom(14)
        self.power.connect("clicked", lambda _: self.on_power())
        win.action_widgets.append(self.power)

        self.title = Gtk.Label(label="Обход выключен", justify=Gtk.Justification.CENTER, wrap=True)
        self.title.add_css_class("hero-title")
        self.subtitle = Gtk.Label(justify=Gtk.Justification.CENTER, wrap=True)
        self.subtitle.add_css_class("hero-subtitle")
        self.hero.append(self.power)
        self.hero.append(self.title)
        self.hero.append(self.subtitle)

        self.progress_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.progress_box.set_margin_top(14)
        self.progress_label = Gtk.Label(wrap=True, justify=Gtk.Justification.CENTER)
        self.progress = Gtk.ProgressBar()
        self.progress_cancel = Gtk.Button(label="Остановить", halign=Gtk.Align.CENTER)
        self.progress_cancel.add_css_class("pill")
        self.progress_cancel.connect("clicked", lambda _: win.cancel_test())
        self.progress_box.append(self.progress_label)
        self.progress_box.append(self.progress)
        self.progress_box.append(self.progress_cancel)
        self.progress_box.set_visible(False)
        self.hero.append(self.progress_box)
        box.append(self.hero)

        trouble = Adw.PreferencesGroup(
            title="Сайт не открывается?",
            description="У разных провайдеров работают разные стратегии, а со временем рабочая может перестать помогать.",
        )
        self.next_row = link_row(
            "Следующая стратегия", "Самый быстрый способ. Можно нажимать несколько раз", "media-skip-forward-symbolic", self.on_next
        )
        self.auto_row = link_row(
            "Подобрать автоматически", "Проверит текущую и, если она не работает, найдёт рабочую", "view-refresh-symbolic", self.on_auto
        )
        self.test_row = link_row(
            "Полная проверка всех стратегий", "Покажет результат каждой, займёт несколько минут", "view-list-symbolic", lambda: win.show_page("strategies")
        )
        self.sites_row = link_row(
            "Добавить свой сайт", "Обход работает только для сайтов из списка", "web-browser-symbolic", lambda: win.show_page("sites")
        )
        for row in (self.next_row, self.auto_row, self.test_row, self.sites_row):
            trouble.add(row)
        win.action_widgets += [self.next_row, self.auto_row]
        box.append(trouble)

        updates = Adw.PreferencesGroup(title="Обновления")
        self.version_row = action_row("Zapret Cap", "")
        self.version_row.add_prefix(Gtk.Image.new_from_icon_name("software-update-available-symbolic"))
        self.update_button = centered_button("Проверить обновления", "suggested-action")
        self.update_button.connect("clicked", lambda _: self.on_check_updates())
        win.action_widgets.append(self.update_button)
        self.version_row.add_suffix(self.update_button)
        updates.add(self.version_row)
        box.append(updates)

    def refresh(self, state):
        version, flowseal = state.get("version"), state.get("flowseal")
        if version:
            self.version_row.set_title(GLib.markup_escape_text(f"Zapret Cap {version}"))
            self.version_row.set_subtitle(GLib.markup_escape_text(f"Стратегии Flowseal {flowseal}"))
        running = state.running
        self.hero.remove_css_class("hero-on" if not running else "hero-off")
        self.hero.add_css_class("hero-on" if running else "hero-off")
        self.title.set_label("Обход работает" if running else "Обход выключен")
        if running:
            self.subtitle.set_label(f"Стратегия: {state.strategy}")
        elif state.get("current"):
            self.subtitle.set_label(f"Нажмите кнопку, чтобы включить стратегию {state.get('current')}")
        else:
            self.subtitle.set_label("Нажмите кнопку, и приложение подберёт подходящую стратегию")

    def on_power(self):
        state = self.win.state
        if state.running:
            self.win.run_job(["stop"], "Выключаю обход…")
        elif state.get("current"):
            self.win.run_job(["start"], f"Включаю стратегию {state.get('current')}…", on_done=self.win.after_switch)
        else:
            self.win.ask(
                "Стратегия ещё не выбрана",
                "Приложение может само найти рабочую стратегию: это займёт от минуты до нескольких минут. "
                "Или можно сразу включить стратегию general и проверить сайты.",
                [("later", "Отмена", None), ("general", "Включить general", None), ("auto", "Подобрать", "suggested")],
                lambda answer: self.on_power_answer(answer),
            )

    def on_power_answer(self, answer):
        if answer == "auto":
            self.on_auto()
        elif answer == "general":
            self.win.run_job(["use", "general"], "Включаю стратегию general…", on_done=self.win.after_switch)

    def on_check_updates(self):
        """Одно нажатие: проверить стратегии Flowseal и само приложение, а новую версию приложения сразу поставить.
        Пароль спросит сама система, а новые стратегии Flowseal ставятся только вместе с новой версией приложения."""

        def flowseal_done(rc, lines):
            flowseal = next(iter(be.visible_lines(lines)), "")
            self.win.run_job(
                ["upgrade", "--check"], "Проверяю, вышла ли новая версия приложения…", root=False,
                on_done=lambda rc2, lines2: app_done(rc2, lines2, flowseal),
            )

        def app_done(rc, lines, flowseal):
            info = be.UpgradeInfo(rc, "\n".join(lines))
            if info.ok and info.newer:
                self.win.start_upgrade(info)
                return
            if info.ok:
                text = f"Установлена последняя версия {info.current or self.win.state.get('version')}."
            else:
                text = f"Не удалось проверить обновление приложения: {info.reason}."
            self.win.toast(f"{text} {flowseal}".strip())

        self.win.run_job(["update-check"], "Проверяю обновления…", root=False, on_done=flowseal_done)

    def on_next(self):
        self.win.run_job(["next"], "Переключаю на следующую стратегию…", on_done=self.win.after_switch)

    def on_auto(self):
        self.progress_label.set_label("Проверяю текущую стратегию…")
        self.progress.set_fraction(0)
        self.progress_box.set_visible(True)

        def on_line(line):
            fields = line[1:].split("\t") if line.startswith("@progress") else None
            if fields and len(fields) == 4:
                number, total, name = int(fields[1]), int(fields[2]), fields[3]
                self.progress_label.set_label(f"Проверяю {name}")
                self.progress.set_fraction((number - 1) / max(total, 1))

        def on_done(rc, lines):
            self.progress_box.set_visible(False)
            if rc == be.TEST_CANCELLED:
                self.win.toast("Подбор остановлен, прежняя стратегия возвращена")
            elif rc == 0:
                self.win.toast(be.last_message(lines, "Готово"))
            else:
                self.win.show_failure("Не удалось подобрать стратегию", lines)

        self.win.run_job(["auto", "--machine"], "Подбираю рабочую стратегию…", on_line=on_line, on_done=on_done, testing=True)


# вид проверки: значение для утилиты, подпись в списке и пояснение под ним
TEST_KINDS = [
    ("full", "Сайты и замирание", "Рекомендуется: открытие сайтов и замирание соединения на 16-20 КБ"),
    ("standard", "Только сайты", "Быстрее, но не покажет замирание на 16-20 КБ"),
    ("dpi", "Только замирание", "Замирание соединения на 16-20 КБ без проверки сайтов"),
]


class StrategiesPage:
    def __init__(self, win):
        self.win = win
        self.widget, box = page_container()
        self.rows = {}
        self.names = []
        self.strategies = []
        self.by_name = {}
        self.best = ""
        self.run_results = {}
        self.run_kind = "full"

        check = Adw.PreferencesGroup(
            title="Проверка стратегий",
            description="Приложение по очереди включит стратегии и проверит, открываются ли сайты и не замирает ли соединение "
            "после первых 16-20 КБ. На это время обход отключается, а потом возвращается.",
        )
        self.kind = Adw.ComboRow(title="Что проверять", model=Gtk.StringList.new([label for _, label, _ in TEST_KINDS]))
        self.kind.set_subtitle(TEST_KINDS[0][2])
        self.kind.connect("notify::selected", lambda *_: self.kind.set_subtitle(TEST_KINDS[self.kind.get_selected()][2]))
        self.scope = Adw.ComboRow(title="Какие стратегии", model=Gtk.StringList.new(["Все", "Отмеченные"]))
        self.scope.connect("notify::selected", lambda *_: self.apply_scope())
        check.add(self.kind)
        check.add(self.scope)
        box.append(check)

        self.start = pill_button("Начать проверку")
        self.start.connect("clicked", lambda _: self.on_start())
        win.action_widgets.append(self.start)
        box.append(self.start)

        self.running_card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        self.running_card.add_css_class("card")
        self.running_card.add_css_class("card-padded")
        self.running_label = Gtk.Label(xalign=0, wrap=True)
        self.running_label.add_css_class("heading")
        self.progress = Gtk.ProgressBar()
        self.stop = pill_button("Остановить", "destructive-action")
        self.stop.connect("clicked", lambda _: win.cancel_test())
        self.log_buffer = Gtk.TextBuffer()
        log_view = Gtk.TextView(buffer=self.log_buffer, editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        log_view.add_css_class("log-view")
        log_scroll = Gtk.ScrolledWindow(min_content_height=180, hscrollbar_policy=Gtk.PolicyType.NEVER)
        log_scroll.set_child(log_view)
        self.log_view = log_view
        expander = Gtk.Expander(label="Подробности")
        expander.set_child(log_scroll)
        for widget in (self.running_label, self.progress, expander, self.stop):
            self.running_card.append(widget)
        self.running_card.set_visible(False)
        box.append(self.running_card)

        self.best_group = Adw.PreferencesGroup(title="Результат проверки")
        self.best_row = action_row("", "")
        best_icon = Gtk.Image.new_from_icon_name("object-select-symbolic")
        best_icon.add_css_class("success")
        self.best_row.add_prefix(best_icon)
        self.best_button = centered_button("Включить", "suggested-action")
        self.best_button.connect("clicked", lambda _: self.best and self.apply(self.best))
        win.action_widgets.append(self.best_button)
        self.best_row.add_suffix(self.best_button)
        self.best_group.add(self.best_row)
        self.report_row = link_row("Открыть папку с отчётами", "Подробный результат по каждому сайту", "folder-open-symbolic", win.open_results)
        self.best_group.add(self.report_row)
        self.best_group.set_visible(False)
        box.append(self.best_group)

        self.list_group = Adw.PreferencesGroup(
            title="Все стратегии",
            description="Сначала стратегии, которые открывают больше сайтов, при равенстве — с меньшим замиранием на 16-20 КБ. "
            "Нажмите на стратегию, чтобы включить её.",
        )
        box.append(self.list_group)

    def refresh(self, state):
        for name, row in self.rows.items():
            row.running_pill.set_visible(state.running and name == state.get("running_strategy"))
            row.current_icon.set_visible(not state.running and name == state.get("current"))

    def set_strategies(self, strategies):
        """Полный список из zapret list --tsv. names хранит порядок утилиты: по нему считаются номера для теста."""
        self.strategies = strategies
        self.names = [item.name for item in sorted(strategies, key=lambda item: item.index)]
        self.by_name = {item.name: item for item in strategies}
        for row in list(self.rows.values()):
            self.list_group.remove(row)
        previous = {name: row.pick.get_active() for name, row in self.rows.items()}
        self.rows = {}
        for item in be.sort_strategies(strategies):
            row = self.make_row(item)
            row.pick.set_active(previous.get(item.name, False))
            self.rows[item.name] = row
            self.list_group.add(row)
        self.apply_scope()
        self.refresh(self.win.state)
        if self.best_group.get_visible():
            self.show_best()

    def make_row(self, item):
        row = action_row(item.name)
        row.set_activatable(True)
        row.connect("activated", lambda _: self.apply(item.name))
        row.pick = Gtk.CheckButton(valign=Gtk.Align.CENTER)
        row.add_prefix(row.pick)
        row.running_pill = badge("Работает", "badge-running")
        row.running_pill.set_visible(False)
        row.current_icon = Gtk.Image.new_from_icon_name("object-select-symbolic")
        row.current_icon.set_tooltip_text("Выбрана, но сейчас выключена")
        row.current_icon.set_visible(False)
        # два результата рядом и по отдельности: сколько сайтов открылось и сколько проверок замерло на 16-20 КБ
        row.sites_badge = badge("")
        row.freeze_badge = badge("")
        for widget in (row.sites_badge, row.freeze_badge):
            widget.add_css_class("badge-result")
        row.add_suffix(row.running_pill)
        row.add_suffix(row.current_icon)
        row.add_suffix(row.sites_badge)
        row.add_suffix(row.freeze_badge)
        self.fill_row(row, item)
        return row

    @staticmethod
    def set_badge(widget, text, kind, tooltip):
        widget.set_label(text)
        for old in ("badge-good", "badge-mid", "badge-bad", "badge-neutral"):
            widget.remove_css_class(old)
        widget.add_css_class(kind)
        widget.set_tooltip_text(tooltip)

    def fill_row(self, row, item):
        if item.sites_tested:
            sites_tip = f"Открылось {item.ok} проверок сайтов из {item.sites_total}"
        else:
            sites_tip = "не проверялось"
        if item.dpi_tested:
            freeze_tip = f"Замерло на 16-20 КБ {item.dpi_blocked or 0} проверок из {item.dpi_total}"
        else:
            freeze_tip = "не проверялось"
        self.set_badge(row.sites_badge, f"сайты {item.sites_text()}", item.sites_kind(), sites_tip)
        self.set_badge(row.freeze_badge, f"замирание {item.freeze_text()}", item.freeze_kind(), freeze_tip)

    def apply_scope(self):
        picking = self.scope.get_selected() == 1
        for row in self.rows.values():
            row.pick.set_visible(picking)

    def apply(self, name):
        self.win.run_job(["use", name], f"Включаю стратегию {name}…", on_done=self.win.after_switch)

    def selection(self):
        if self.scope.get_selected() == 0:
            return "all"
        numbers = [str(index + 1) for index, name in enumerate(self.names) if self.rows[name].pick.get_active()]
        return ",".join(numbers)

    def on_start(self):
        selection = self.selection()
        if not selection:
            self.win.toast("Отметьте хотя бы одну стратегию в списке")
            return
        if self.win.state.foreign:
            self.win.ask(
                "Работает другое средство обхода",
                "Результаты проверки будут неточными: " + ", ".join(self.win.state.foreign) + "\n\nОстановить его можно на вкладке «Помощь».",
                [("cancel", "Отмена", None), ("go", "Всё равно проверить", "destructive")],
                lambda answer: answer == "go" and self.begin(selection, True),
            )
        else:
            self.begin(selection, False)

    def begin(self, selection, force):
        self.run_kind = TEST_KINDS[self.kind.get_selected()][0]
        self.run_results = {}
        self.best = ""
        self.best_group.set_visible(False)
        self.running_card.set_visible(True)
        self.running_label.set_label("Подготовка…")
        self.progress.set_fraction(0)
        self.log_buffer.set_text("")
        args = ["test", self.run_kind, selection, "--machine"] + (["--force"] if force else [])
        self.win.run_job(args, "Идёт проверка стратегий…", on_line=self.on_line, on_done=self.on_done, testing=True)

    def on_line(self, line):
        if not line.startswith("@"):
            self.log_buffer.insert(self.log_buffer.get_end_iter(), line + "\n")
            return
        fields = line[1:].split("\t")
        if fields[0] == "progress" and len(fields) == 4:
            number, total = int(fields[1]), int(fields[2])
            self.running_label.set_label(f"Стратегия {number} из {total}: {fields[3]}")
            self.progress.set_fraction((number - 1) / max(total, 1))
        elif fields[0] == "result" and len(fields) >= 3:
            values = [int(value) for value in fields[2:] if value.strip().lstrip("-").isdigit()]
            self.run_results[fields[1]] = values
            # строка сразу показывает новый результат, а порядок меняется после проверки, чтобы список не прыгал
            item = self.by_name.get(fields[1])
            if item and item.apply_result(values):
                self.update_row(item)
        # общий балл утилита печатает только для совместимости: окно показывает результаты по отдельности
        elif fields[0] == "best" and len(fields) >= 2:
            self.best = fields[1]

    def update_row(self, item):
        row = self.rows.get(item.name)
        if row:
            self.fill_row(row, item)

    def show_best(self):
        item = self.by_name.get(self.best)
        if not item:
            self.best_group.set_visible(False)
            return
        self.best_row.set_title(f"Лучшая стратегия: {GLib.markup_escape_text(item.name)}")
        self.best_row.set_subtitle(GLib.markup_escape_text(item.summary()))
        self.best_group.set_visible(True)

    def on_done(self, rc, lines):
        self.running_card.set_visible(False)
        if rc == be.TEST_CANCELLED:
            self.run_results = {}
            self.win.toast("Проверка остановлена, прежний обход возвращён")
            self.win.reload_strategies()
            return
        if rc != 0:
            self.win.show_failure("Проверка не удалась", lines)
            self.win.reload_strategies()
            return
        if not self.best:
            # утилита не назвала лучшую: больше сайтов, затем меньше замирания
            best = be.best_strategy(self.strategies)
            self.best = best.name if best else ""
        if self.best:
            self.show_best()
        else:
            self.win.toast("Ни одна стратегия не запустилась")
        # утилита сохранила результаты, в том числе прошлых проверок: порядок строится по ним
        self.win.reload_strategies()


class SitesPage:
    def __init__(self, win):
        self.win = win
        self.widget, box = page_container()
        self.rows = {}

        add = Adw.PreferencesGroup(
            title="Добавить сайт",
            description="Обход работает только для сайтов из этого списка. Можно вставить ссылку целиком: приложение само оставит нужную часть. "
            "Поддомены учитываются автоматически, перезапуск не нужен.",
        )
        entry_box = Gtk.Box(spacing=8)
        self.entry = Gtk.Entry(hexpand=True, placeholder_text="example.com или ссылка из браузера")
        self.entry.connect("activate", lambda _: self.on_add())
        self.add_button = Gtk.Button(label="Добавить")
        self.add_button.add_css_class("suggested-action")
        self.add_button.connect("clicked", lambda _: self.on_add())
        win.action_widgets.append(self.add_button)
        entry_box.append(self.entry)
        entry_box.append(self.add_button)
        add.add(entry_box)
        box.append(add)

        self.search = Gtk.SearchEntry(placeholder_text="Поиск по списку")
        self.search.connect("search-changed", lambda _: self.apply_filter())
        box.append(self.search)

        self.list_group = Adw.PreferencesGroup(title="Сайты в списке")
        box.append(self.list_group)

    def set_domains(self, domains):
        self.list_group.set_title(f"Сайты в списке: {len(domains)}")
        for row in self.rows.values():
            self.list_group.remove(row)
        self.rows = {}
        for domain in domains:
            # ^ в начале значит точное совпадение: так записаны поддомены в оригинальном списке
            row = action_row(domain.lstrip("^"))
            remove = Gtk.Button(icon_name="user-trash-symbolic", valign=Gtk.Align.CENTER)
            remove.add_css_class("flat")
            remove.set_tooltip_text("Убрать из списка")
            remove.connect("clicked", lambda _, name=domain: self.on_remove(name))
            row.add_suffix(remove)
            self.rows[domain] = row
            self.list_group.add(row)
        self.apply_filter()

    def apply_filter(self):
        needle = self.search.get_text().strip().lower()
        for domain, row in self.rows.items():
            row.set_visible(needle in domain)

    def on_add(self):
        words = self.entry.get_text().split()
        if not words:
            self.entry.grab_focus()
            return

        def on_done(rc, lines):
            self.report(lines)
            if not any(line.endswith("не похоже на домен.") or "IP-адрес" in line for line in lines):
                self.entry.set_text("")
            self.win.reload_domains()

        self.win.run_job(["add", *words], "Добавляю сайт…", on_done=on_done)

    def on_remove(self, domain):
        self.win.ask(
            f"Убрать {domain.lstrip('^')}?",
            "Обход для этого сайта перестанет работать.",
            [("cancel", "Отмена", None), ("remove", "Убрать", "destructive")],
            lambda answer: answer == "remove" and self.remove(domain),
        )

    def remove(self, domain):
        def on_done(rc, lines):
            self.report(lines)
            self.win.reload_domains()

        self.win.run_job(["remove", domain.lstrip("^")], "Убираю сайт…", on_done=on_done)

    def report(self, lines):
        useful = [line.strip() for line in be.visible_lines(lines) if not line.startswith("Перезапуск не нужен")]
        self.win.toast(" ".join(useful) or "Готово")


class SettingsPage:
    def __init__(self, win):
        self.win = win
        self.widget, box = page_container()
        self.updating = False
        self.fake_files = []

        general = Adw.PreferencesGroup(title="Основные")
        self.autostart = self.switch_row(general, "Запускать вместе с компьютером", "Обход будет включаться сам", self.on_autostart)
        self.shortcut = self.switch_row(general, "Ярлык на рабочем столе", "", self.on_shortcut)
        box.append(general)

        game = Adw.PreferencesGroup(
            title="Фильтр игр",
            description="Обход для игр и других программ на портах выше 1023. Работает только для адресов из IPSet, поэтому обычно нужен ещё режим IPSet «Из списка».",
        )
        self.game_mode = Adw.ComboRow(title="Режим", model=Gtk.StringList.new([label for _, label in GAME_MODES]))
        self.game_mode.connect("notify::selected", lambda *_: self.on_game_mode())
        game.add(self.game_mode)
        self.tcp_entry, tcp_row = self.ports_row("Порты TCP", "tcp")
        self.udp_entry, udp_row = self.ports_row("Порты UDP", "udp")
        game.add(tcp_row)
        game.add(udp_row)
        box.append(game)

        ipset = Adw.PreferencesGroup(title="IPSet", description="Какие IP-адреса обрабатывать, кроме сайтов из списка.")
        self.ipset_mode = Adw.ComboRow(title="Режим", model=Gtk.StringList.new([label for _, label, _ in IPSET_MODES]))
        self.ipset_mode.connect("notify::selected", lambda *_: self.on_ipset_mode())
        ipset.add(self.ipset_mode)
        update_row = action_row("Список адресов", "Скачать свежий список из репозитория Flowseal")
        update_button = centered_button("Обновить")
        update_button.connect("clicked", lambda _: win.run_job(["ipset", "update"], "Скачиваю список IPSet…"))
        win.action_widgets.append(update_button)
        update_row.add_suffix(update_button)
        ipset.add(update_row)
        box.append(ipset)

        fakes = Adw.PreferencesGroup(title="Активные фейки", description="Для опытных: какими данными маскируется трафик Discord и игр.")
        self.fake_discord = Adw.ComboRow(title="Discord UDP")
        self.fake_discord.connect("notify::selected", lambda *_: self.on_fake("discord", self.fake_discord))
        self.fake_game = Adw.ComboRow(title="Фильтр игр UDP")
        self.fake_game.connect("notify::selected", lambda *_: self.on_fake("game", self.fake_game))
        fakes.add(self.fake_discord)
        fakes.add(self.fake_game)
        box.append(fakes)

        updates = Adw.PreferencesGroup(title="Обновления", description="Проверить обновления можно на главной вкладке.")
        self.update_check = self.switch_row(
            updates, "Сообщать об обновлениях", "Новые версии приложения и стратегий Flowseal", self.on_update_check
        )
        hosts_row = action_row("Файл hosts", "Может починить веб-версию Telegram и голосовые каналы Discord")
        hosts_button = centered_button("Проверить")
        hosts_button.connect("clicked", lambda _: self.on_hosts())
        win.action_widgets.append(hosts_button)
        hosts_row.add_suffix(hosts_button)
        updates.add(hosts_row)
        box.append(updates)

        danger = Adw.PreferencesGroup(title="Удаление")
        remove_row = action_row("Удалить приложение", "Вместе с добавленными сайтами и настройками")
        remove_button = centered_button("Удалить", "destructive-action")
        remove_button.connect("clicked", lambda _: self.on_uninstall())
        win.action_widgets.append(remove_button)
        remove_row.add_suffix(remove_button)
        danger.add(remove_row)
        box.append(danger)

    @staticmethod
    def switch_row(group, title, subtitle, callback):
        row = action_row(title, subtitle)
        switch = Gtk.Switch(valign=Gtk.Align.CENTER)
        switch.connect("notify::active", lambda *_: callback(switch.get_active()))
        row.add_suffix(switch)
        row.set_activatable_widget(switch)
        group.add(row)
        switch.row = row
        return switch

    def ports_row(self, title, proto):
        row = action_row(title)
        entry = Gtk.Entry(valign=Gtk.Align.CENTER, placeholder_text="1024-65535", width_chars=20)
        button = centered_button("Применить")
        button.connect("clicked", lambda _: self.on_ports(proto, entry))
        entry.connect("activate", lambda _: self.on_ports(proto, entry))
        self.win.action_widgets.append(button)
        row.add_suffix(entry)
        row.add_suffix(button)
        return entry, row

    def refresh(self, state):
        self.updating = True
        self.autostart.set_active(state.get("autostart") == "1")
        self.autostart.row.set_subtitle(
            "Обход будет включаться сам" if state.flag("systemd") else "В этой системе нет systemd: автозапуск настраивается вручную"
        )
        modes = [mode for mode, _ in GAME_MODES]
        self.game_mode.set_selected(modes.index(state.get("game_mode")) if state.get("game_mode") in modes else 0)
        self.set_entry(self.tcp_entry, state.get("game_tcp"))
        self.set_entry(self.udp_entry, state.get("game_udp"))
        ipsets = [mode for mode, _, _ in IPSET_MODES]
        ipset = state.get("ipset")
        if ipset in ipsets:
            self.ipset_mode.set_selected(ipsets.index(ipset))
            self.ipset_mode.set_subtitle(IPSET_MODES[ipsets.index(ipset)][2])
        self.update_check.set_active(state.flag("update_check"))
        self.shortcut.set_sensitive(self.win.desktop_entry() is not None)
        self.shortcut.set_active(os.path.exists(self.win.shortcut_path()))
        self.shortcut.row.set_subtitle(
            "Значок Zapret Cap на рабочем столе" if self.win.desktop_entry() else "Появится после установки приложения"
        )
        self.updating = False

    @staticmethod
    def set_entry(entry, text):
        # опрос состояния не должен стирать то, что человек сейчас вводит
        if entry.get_focus_child() is None:
            entry.set_text(text)

    def set_fakes(self, active, files):
        self.updating = True
        self.fake_files = files
        for combo, key in ((self.fake_discord, "discord"), (self.fake_game, "game")):
            combo.set_model(Gtk.StringList.new(files))
            if active.get(key) in files:
                combo.set_selected(files.index(active[key]))
        self.updating = False

    def on_autostart(self, active):
        if not self.updating:
            self.win.run_job(["autostart", "on" if active else "off"], "Меняю автозапуск…")

    def on_shortcut(self, active):
        if not self.updating:
            self.win.set_shortcut(active)

    def on_game_mode(self):
        if not self.updating:
            mode = GAME_MODES[self.game_mode.get_selected()][0]
            self.win.run_job(["game", "off" if mode == "disabled" else mode], "Меняю фильтр игр…")

    def on_ports(self, proto, entry):
        text = entry.get_text().replace(" ", "")
        if not PORTS_RE.match(text):
            self.win.toast("Неверные порты. Пример: 1024-1934,1936-65535")
            return
        self.win.run_job(["game-ports", proto, text], "Меняю порты…")

    def on_ipset_mode(self):
        if not self.updating:
            self.win.run_job(["ipset", IPSET_MODES[self.ipset_mode.get_selected()][0]], "Меняю режим IPSet…")

    def on_fake(self, kind, combo):
        if self.updating or combo.get_selected() >= len(self.fake_files):
            return

        def on_done(rc, lines):
            self.win.finish_default(rc, lines)
            self.win.reload_fakes()

        self.win.run_job(["fakes", "set", kind, self.fake_files[combo.get_selected()]], "Меняю фейк…", on_done=on_done)

    def on_update_check(self, active):
        if not self.updating:
            self.win.run_job(["update-check", "on" if active else "off"], "Меняю настройку…")

    def on_hosts(self):
        def on_done(rc, lines):
            if rc == 0:
                self.win.toast(be.last_message(lines, "Файл hosts актуален"))
            elif rc == be.HOSTS_OUTDATED:
                self.win.ask(
                    "Обновить файл hosts?",
                    be.last_message(lines) + "\n\nСтроки будут добавлены в /etc/hosts, а копия сохранится рядом с ним.",
                    [("cancel", "Отмена", None), ("write", "Обновить", "suggested")],
                    lambda answer: answer == "write" and self.win.run_job(["hosts", "--yes"], "Обновляю файл hosts…"),
                )
            else:
                self.win.show_failure("Не удалось проверить файл hosts", lines)

        self.win.run_job(["hosts", "--check"], "Проверяю файл hosts…", root=False, on_done=on_done)

    def on_uninstall(self):
        def on_done(rc, lines):
            if rc == 0:
                self.win.get_application().quit()
            else:
                self.win.show_failure("Не удалось удалить приложение", lines)

        self.win.ask(
            "Удалить Zapret Cap?",
            "Обход будет выключен. Добавленные сайты и настройки удалятся вместе с приложением.",
            [("cancel", "Отмена", None), ("remove", "Удалить", "destructive")],
            lambda answer: answer == "remove" and self.win.run_job(["uninstall", "--yes"], "Удаляю приложение…", on_done=on_done),
        )


class DiagnosticsPage:
    def __init__(self, win):
        self.win = win
        self.widget, box = page_container()
        self.result_rows = []

        intro = Adw.PreferencesGroup(
            title="Поиск проблем",
            description="Проверит движок, файрвол, VPN, прокси и другие частые причины, по которым обход не работает.",
        )
        box.append(intro)
        self.run_button = pill_button("Проверить")
        self.run_button.connect("clicked", lambda _: self.on_run())
        win.action_widgets.append(self.run_button)
        box.append(self.run_button)

        self.results = Adw.PreferencesGroup(title="Результат")
        self.results.set_visible(False)
        box.append(self.results)

        self.conflict_group = Adw.PreferencesGroup(
            title="Другие средства обхода",
            description="Вместе с этим приложением они мешают друг другу. Службы будут остановлены и отключены, файлы останутся на месте.",
        )
        self.conflict_row = action_row("", "", "dialog-warning-symbolic")
        self.conflict_button = centered_button("Остановить", "destructive-action")
        self.conflict_button.connect("clicked", lambda _: self.on_stop_foreign())
        win.action_widgets.append(self.conflict_button)
        self.conflict_row.add_suffix(self.conflict_button)
        self.conflict_group.add(self.conflict_row)
        box.append(self.conflict_group)

        tools = Adw.PreferencesGroup(title="Что ещё может помочь")
        discord = action_row("Очистить кэш Discord", "Если Discord не подключается. Он будет закрыт, если запущен")
        discord_button = centered_button("Очистить")
        discord_button.connect("clicked", lambda _: self.on_discord())
        win.action_widgets.append(discord_button)
        discord.add_suffix(discord_button)
        tools.add(discord)
        dns = Adw.ExpanderRow(title="Защищённый DNS в браузере", subtitle="Без него провайдер может подменять адреса сайтов")
        dns.add_row(action_row("Chrome, Chromium, Яндекс Браузер", "Настройки → Конфиденциальность и безопасность → Безопасность → «Использовать безопасный DNS»"))
        dns.add_row(action_row("Firefox", "Настройки → Приватность и защита → «DNS через HTTPS» → «Максимальная защита»"))
        tools.add(dns)
        tools.add(link_row("Отчёты о проверке стратегий", "Папка с подробными результатами", "folder-open-symbolic", win.open_results))
        tools.add(link_row("Журнал действий", "Что выводили команды приложения", "utilities-terminal-symbolic", win.show_log))
        box.append(tools)

    def refresh(self, state):
        self.conflict_group.set_visible(bool(state.foreign))
        if state.foreign:
            self.conflict_row.set_title(GLib.markup_escape_text(", ".join(state.foreign)))

    def on_run(self):
        self.win.run_job(["diag"], "Ищу проблемы…", on_done=self.on_done)

    def on_done(self, rc, lines):
        for row in self.result_rows:
            self.results.remove(row)
        self.result_rows = []
        sections = be.parse_diagnostics(lines)
        icons = {
            "ok": ("object-select-symbolic", "success"),
            "warning": ("dialog-warning-symbolic", "warning"),
            "error": ("dialog-error-symbolic", "error"),
        }
        for level, title, details in sections:
            row = action_row(title, details)
            icon = Gtk.Image.new_from_icon_name(icons[level][0])
            icon.add_css_class(icons[level][1])
            row.add_prefix(icon)
            self.results.add(row)
            self.result_rows.append(row)
        self.results.set_visible(bool(sections))
        problems = sum(1 for level, _, _ in sections if level != "ok")
        self.win.toast(f"Проверка закончена. Обратите внимание на пункты: {problems}" if problems else "Проблем не найдено")

    def on_stop_foreign(self):
        self.win.ask(
            "Остановить другие средства обхода?",
            ", ".join(self.win.state.foreign) + "\n\nИх службы будут остановлены и убраны из автозапуска. Файлы останутся на месте.",
            [("cancel", "Отмена", None), ("stop", "Остановить", "destructive")],
            lambda answer: answer == "stop" and self.win.run_job(["stop-foreign"], "Останавливаю…"),
        )

    def on_discord(self):
        self.win.ask(
            "Очистить кэш Discord?",
            "Discord будет закрыт, если запущен. Настройки и вход в аккаунт не пострадают.",
            [("cancel", "Отмена", None), ("clear", "Очистить", "suggested")],
            lambda answer: answer == "clear" and self.win.run_job(["clear-discord"], "Очищаю кэш Discord…"),
        )


class MainWindow(Adw.ApplicationWindow):
    def __init__(self, app, backend):
        super().__init__(application=app, title="Zapret Cap", default_width=860, default_height=780)
        self.backend = backend
        self.state = be.State()
        self.job = None
        self.job_is_test = False
        self.action_widgets = []
        self.log_lines = []
        self.polling = False

        self.overlay = Adw.ToastOverlay()
        self.set_content(self.overlay)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.overlay.set_child(root)

        header = Adw.HeaderBar()
        self.stack = Adw.ViewStack(vexpand=True)
        switcher = Adw.ViewSwitcher(stack=self.stack, policy=Adw.ViewSwitcherPolicy.WIDE)
        header.set_title_widget(switcher)
        menu = Gio.Menu()
        menu.append("Журнал действий", "win.log")
        menu.append("О приложении", "win.about")
        menu_button = Gtk.MenuButton(icon_name="open-menu-symbolic", menu_model=menu, primary=True)
        header.pack_end(menu_button)
        for name, callback in (("log", self.show_log), ("about", self.show_about)):
            action = Gio.SimpleAction.new(name, None)
            action.connect("activate", lambda _a, _b, cb=callback: cb())
            self.add_action(action)
        root.append(header)

        self.busy_strip = Gtk.Box(spacing=10)
        self.busy_strip.add_css_class("busy-strip")
        self.spinner = Gtk.Spinner()
        self.busy_label = Gtk.Label(xalign=0, wrap=True, hexpand=True)
        self.busy_strip.append(self.spinner)
        self.busy_strip.append(self.busy_label)
        self.busy_reveal = Gtk.Revealer(child=self.busy_strip, transition_type=Gtk.RevealerTransitionType.SLIDE_DOWN)
        root.append(self.busy_reveal)

        self.notices = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.notice_foreign = self.make_notice("notice-warning", "Подробнее", lambda: self.show_page("diagnostics"))
        self.notice_engine = self.make_notice("notice-warning", None, None)
        self.notice_update = self.make_notice("notice-info", "Открыть", lambda: self.open_uri(RELEASES_URL))
        self.notice_app = self.make_notice("notice-info", "Обновить", lambda: self.start_upgrade(self.upgrade_info))
        self.notice_app.button.add_css_class("suggested-action")
        self.action_widgets.append(self.notice_app.button)
        self.upgrade_info = None
        self.upgrade_checked = False
        self.restarting = False
        root.append(self.notices)
        root.append(self.stack)

        self.home = HomePage(self)
        self.strategies = StrategiesPage(self)
        self.sites = SitesPage(self)
        self.settings = SettingsPage(self)
        self.diagnostics = DiagnosticsPage(self)
        for name, title, icon, page in (
            ("home", "Главная", "system-shutdown-symbolic", self.home),
            ("strategies", "Стратегии", "view-list-symbolic", self.strategies),
            ("sites", "Сайты", "web-browser-symbolic", self.sites),
            ("settings", "Настройки", "emblem-system-symbolic", self.settings),
            ("diagnostics", "Помощь", "dialog-question-symbolic", self.diagnostics),
        ):
            self.stack.add_titled(page.widget, name, title).set_icon_name(icon)

        self.connect("close-request", self.on_close)
        self.reload_all()
        GLib.timeout_add_seconds(POLL_SECONDS, self.poll)

    def make_notice(self, css, button_label, callback):
        box = Gtk.Box(spacing=12)
        box.add_css_class("notice")
        box.add_css_class(css)
        box.label = Gtk.Label(xalign=0, wrap=True, hexpand=True)
        box.append(box.label)
        box.button = None
        if button_label:
            button = Gtk.Button(label=button_label, valign=Gtk.Align.CENTER)
            button.add_css_class("flat")
            button.connect("clicked", lambda _: callback())
            box.append(button)
            box.button = button
        box.set_visible(False)
        self.notices.append(box)
        return box

    # --- состояние

    def poll(self):
        if self.get_mapped() and not self.polling:
            self.polling = True
            in_background(self.backend.state, self.apply_state)
        return True

    def apply_state(self, state):
        self.polling = False
        if state is None:
            return
        self.state = state
        self.home.refresh(state)
        self.strategies.refresh(state)
        self.settings.refresh(state)
        self.diagnostics.refresh(state)

        self.notice_foreign.set_visible(bool(state.foreign))
        if state.foreign:
            self.notice_foreign.label.set_label("Работает другое средство обхода, оно мешает этому приложению: " + ", ".join(state.foreign))
        built = state.get("engine_built", "1") == "1"
        self.notice_engine.set_visible(not built)
        self.notice_engine.label.set_label("Движок не собран, поэтому обход не запустится. Установите приложение заново: bash install.sh")
        # о новой версии приложения узнаём один раз за запуск окна и только если человек не выключил проверку
        if not self.upgrade_checked and state.get("version"):
            self.upgrade_checked = True
            if state.flag("update_check"):
                in_background(self.backend.upgrade_check, self.apply_upgrade_info)
        latest = state.get("update_available")
        self.notice_update.set_visible(bool(latest))
        if latest:
            self.notice_update.label.set_label(f"Вышли новые стратегии Flowseal: {latest}")

    def apply_upgrade_info(self, info):
        """Итог проверки при запуске. Без сети молчим: человек ничего не просил, а обход работает и так."""
        self.upgrade_info = info if info is not None and info.ok else None
        newer = bool(self.upgrade_info and self.upgrade_info.newer)
        self.notice_app.set_visible(newer)
        if newer:
            self.notice_app.label.set_label(f"Доступна новая версия Zapret Cap: {self.upgrade_info.latest}")

    def start_upgrade(self, info=None):
        version = info.latest if info and info.latest else "новой версии"
        self.run_job(["upgrade"], f"Обновляю Zapret Cap до {version}…", on_done=self.after_upgrade)

    def after_upgrade(self, rc, lines):
        if be.upgrade_installed(rc, lines):
            self.notice_app.set_visible(False)
            self.toast("Обновление установлено, окно сейчас откроется заново")
            GLib.timeout_add(1500, self.restart_into_new_version)
        elif rc == 0:
            self.notice_app.set_visible(False)
            self.toast(be.last_message(lines, "Установлена последняя версия"))
        else:
            self.show_failure("Не удалось обновить приложение", lines)

    def restart_into_new_version(self):
        # файлы в папке программы уже заменены, а этот процесс работает со старым кодом
        path = os.path.join(self.backend.home, "zapret-gui")
        if os.environ.get("ZAPRET_GUI_NO_EXEC") or not os.access(path, os.X_OK):
            self.toast("Закройте и снова откройте приложение, чтобы перейти на новую версию")
            return False
        self.restarting = True
        os.execv(path, [path])
        return False

    def reload_all(self):
        self.reload_state()
        self.reload_strategies()
        self.reload_domains()
        self.reload_fakes()

    def reload_state(self):
        in_background(self.backend.state, self.apply_state)

    def reload_strategies(self):
        in_background(self.backend.strategies, lambda items: items is not None and self.strategies.set_strategies(items))

    def reload_domains(self):
        in_background(self.backend.domains, lambda items: items is not None and self.sites.set_domains(items))

    def reload_fakes(self):
        in_background(self.backend.fakes, lambda result: result is not None and self.settings.set_fakes(*result))

    # --- команды

    def run_job(self, args, label, root=True, on_line=None, on_done=None, testing=False):
        if self.job is not None:
            self.toast("Дождитесь окончания текущего действия")
            self.reload_state()
            return
        self.log(f"$ zapret {' '.join(args)}")
        self.set_busy(label + (" Система может спросить пароль." if root and os.geteuid() != 0 else ""))
        self.job_is_test = testing

        def line_seen(line):
            if not line.startswith("@"):
                self.log(line)
            if on_line:
                on_line(line)

        def finished(rc, lines):
            self.job = None
            self.job_is_test = False
            self.set_busy(None)
            if root and rc in be.AUTH_CANCELLED and os.geteuid() != 0:
                self.toast("Действие отменено: пароль администратора не введён")
                if testing and on_done:
                    on_done(be.TEST_CANCELLED, [])
            elif on_done:
                on_done(rc, lines)
            else:
                self.finish_default(rc, lines)
            self.reload_state()

        self.job = self.backend.spawn(args, root=root, on_line=line_seen, on_exit=finished)

    def after_switch(self, rc, lines):
        if rc == 0:
            self.toast(be.last_message(lines, "Готово").split(" (раньше")[0].rstrip(".") + ". Проверьте сайты в браузере")
        else:
            self.show_failure("Стратегия не включилась", lines)

    def finish_default(self, rc, lines):
        if rc == 0:
            self.toast(be.last_message(lines, "Готово"))
        else:
            self.show_failure("Не получилось", lines)

    def cancel_test(self):
        self.backend.spawn(["test-cancel"], root=True)
        self.set_busy("Останавливаю, сейчас обход вернётся в прежнее состояние…")

    def set_busy(self, label):
        busy = label is not None
        if busy:
            self.busy_label.set_label(label)
            self.spinner.start()
        else:
            self.spinner.stop()
        self.busy_reveal.set_reveal_child(busy)
        for widget in self.action_widgets:
            widget.set_sensitive(not busy)
        for row in self.strategies.rows.values():
            row.set_sensitive(not busy or self.job_is_test)
            row.set_activatable(not busy)

    def log(self, line):
        self.log_lines.append(f"{time.strftime('%H:%M:%S')} {line}")
        del self.log_lines[:-2000]

    # --- диалоги

    def toast(self, text):
        self.last_toast = text
        toast = Adw.Toast(title=GLib.markup_escape_text(text))
        toast.set_timeout(5)
        self.overlay.add_toast(toast)

    def show_failure(self, title, lines):
        details = "\n".join(line.strip() for line in be.visible_lines(lines)[-8:]) or "Подробности в журнале действий."
        self.ask(title, details, [("ok", "Понятно", None)], None)

    def ask(self, heading, body, responses, callback):
        modern = hasattr(Adw, "AlertDialog")
        if modern:
            dialog = Adw.AlertDialog(heading=heading, body=body)
        else:
            dialog = Adw.MessageDialog(transient_for=self, heading=heading, body=body)
        for response, label, look in responses:
            dialog.add_response(response, label)
            if look == "suggested":
                dialog.set_response_appearance(response, Adw.ResponseAppearance.SUGGESTED)
            elif look == "destructive":
                dialog.set_response_appearance(response, Adw.ResponseAppearance.DESTRUCTIVE)
        dialog.set_close_response(responses[0][0])
        dialog.set_default_response(responses[-1][0])
        if callback:
            dialog.connect("response", lambda _d, answer: callback(answer))
        if modern:
            dialog.present(self)
        else:
            dialog.present()
        self.last_dialog = dialog

    def show_log(self):
        window = Adw.Window(transient_for=self, modal=True, title="Журнал действий", default_width=720, default_height=520)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        header = Adw.HeaderBar()
        text = "\n".join(self.log_lines) or "Пока здесь пусто: приложение ещё ничего не запускало."
        copy = Gtk.Button(label="Скопировать")
        copy.connect("clicked", lambda _: (self.get_clipboard().set(text), self.toast("Журнал скопирован")))
        header.pack_start(copy)
        box.append(header)
        view = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        view.add_css_class("log-view")
        view.get_buffer().set_text(text)
        scrolled = Gtk.ScrolledWindow(vexpand=True)
        scrolled.set_child(view)
        box.append(scrolled)
        window.set_content(box)
        window.present()

    def show_about(self):
        version = self.state.get("version", "")
        flowseal = self.state.get("flowseal", "")
        comments = f"Обход блокировок на основе zapret2. Стратегии Flowseal {flowseal}."
        if hasattr(Adw, "AboutDialog"):
            about = Adw.AboutDialog(application_name="Zapret Cap", application_icon=APP_ID, version=version, comments=comments,
                                    license_type=Gtk.License.MIT_X11)
        elif hasattr(Adw, "AboutWindow"):
            about = Adw.AboutWindow(transient_for=self, application_name="Zapret Cap", application_icon=APP_ID, version=version,
                                    comments=comments, license_type=Gtk.License.MIT_X11)
        else:
            return
        # своё название у каждой ссылки: одна безымянная «Website» не говорила, куда ведёт
        for title, url in LINKS:
            about.add_link(title, url)
        if hasattr(Adw, "AboutDialog"):
            about.present(self)
        else:
            about.present()
        self.last_about = about

    # --- мелочи

    def show_page(self, name):
        self.stack.set_visible_child_name(name)

    def open_uri(self, uri):
        Gio.AppInfo.launch_default_for_uri(uri, None)

    def open_results(self):
        folder = self.state.get("results_dir")
        if folder and os.path.isdir(folder):
            self.open_uri(Gio.File.new_for_path(folder).get_uri())
        else:
            self.toast("Отчётов пока нет: сначала запустите проверку стратегий")

    @staticmethod
    def desktop_entry():
        for folder in GLib.get_system_data_dirs():
            path = os.path.join(folder, "applications", APP_ID + ".desktop")
            if os.path.exists(path):
                return path
        return None

    @staticmethod
    def shortcut_path():
        desktop = GLib.get_user_special_dir(GLib.UserDirectory.DIRECTORY_DESKTOP) or os.path.expanduser("~/Desktop")
        return os.path.join(desktop, APP_ID + ".desktop")

    def set_shortcut(self, enabled):
        target = self.shortcut_path()
        try:
            if enabled:
                os.makedirs(os.path.dirname(target), exist_ok=True)
                with open(self.desktop_entry(), "rb") as source, open(target, "wb") as copy:
                    copy.write(source.read())
                os.chmod(target, 0o755)
                # без этой отметки GNOME считает ярлык недоверенным и не запускает его
                subprocess.run(["gio", "set", target, "metadata::trusted", "true"], stderr=subprocess.DEVNULL, check=False)
                self.toast("Ярлык добавлен на рабочий стол")
            elif os.path.exists(target):
                os.remove(target)
                self.toast("Ярлык убран с рабочего стола")
        except (OSError, TypeError) as error:
            self.toast(f"Не удалось изменить ярлык: {error}")

    def on_close(self, _window):
        if not self.job_is_test:
            return False

        def answer(response):
            if response == "stop":
                self.cancel_test()
                GLib.timeout_add(300, self.close_when_done)

        self.ask(
            "Идёт проверка стратегий",
            "Чтобы закрыть окно, проверку нужно остановить. Прежний обход вернётся автоматически.",
            [("stay", "Продолжить проверку", None), ("stop", "Остановить и закрыть", "destructive")],
            answer,
        )
        return True

    def close_when_done(self):
        if self.job is None:
            self.close()
            return False
        return True


class Application(Adw.Application):
    def __init__(self):
        flags = Gio.ApplicationFlags.FLAGS_NONE
        # в проверках нет шины сессии, а без неё приложение не сможет зарегистрировать своё имя
        if os.environ.get("ZAPRET_GUI_NON_UNIQUE"):
            flags |= Gio.ApplicationFlags.NON_UNIQUE
        super().__init__(application_id=APP_ID, flags=flags)
        self.window = None

    def do_startup(self):
        Adw.Application.do_startup(self)
        provider = Gtk.CssProvider()
        provider.load_from_path(os.path.join(HERE, "style.css"))
        Gtk.StyleContext.add_provider_for_display(Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        icons = Gtk.IconTheme.get_for_display(Gdk.Display.get_default())
        # из папки репозитория значок берётся рядом с программой, после установки он лежит в системной теме
        icons.add_search_path(os.path.join(os.path.dirname(HERE), "data"))

    def do_activate(self):
        # повторный запуск из меню показывает уже открытое окно
        if self.window is None:
            self.window = MainWindow(self, be.Backend(dispatch))
        self.window.present()


def main():
    # чтобы в доках GNOME окно нашло свой значок
    GLib.set_prgname(APP_ID)
    GLib.set_application_name("Zapret Cap")
    return Application().run(sys.argv)


if __name__ == "__main__":
    sys.exit(main())
