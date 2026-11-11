"""Связь окна с утилитой zapret. GTK здесь нет: всю работу делает та же утилита, что и в терминале,
а окно только запускает её команды и разбирает ответ."""
import os
import subprocess
import threading

# код возврата pkexec: человек закрыл окно пароля или прав нет
AUTH_CANCELLED = (126, 127)
# тест остановлен
TEST_CANCELLED = 130
# zapret hosts --check: файл нужно обновить
HOSTS_OUTDATED = 3


class State:
    """Ответ команды zapret state."""

    def __init__(self, text=""):
        self.values = {}
        self.foreign = []
        for line in text.splitlines():
            key, _, value = line.partition("=")
            if key == "foreign":
                self.foreign.append(value)
            else:
                self.values[key] = value

    def get(self, key, default=""):
        return self.values.get(key, default)

    def flag(self, key):
        return self.values.get(key) == "1"

    @property
    def running(self):
        return self.flag("running")

    @property
    def strategy(self):
        return self.get("running_strategy") or self.get("current")


SITE_FIELDS = ("ok", "err", "unsup", "ping_ok", "ping_fail")
DPI_FIELDS = ("dpi_ok", "dpi_fail", "dpi_unsup", "dpi_blocked")


class Strategy:
    """Строка zapret list --tsv: имя, итоги последних тестов сайтов и замирания на 16-20 КБ.
    Пустое поле значит, что тест для этой стратегии не запускался. Одиннадцатое поле, общую оценку утилиты,
    окно не использует: результаты показываются по отдельности."""

    def __init__(self, line, index=0):
        fields = (line.split("\t") + [""] * 10)[:10]
        self.name = fields[0]
        # место в списке утилиты: по нему тест выбирает стратегии, какой бы ни была сортировка в окне
        self.index = index
        numbers = [int(value) if value.strip().isdigit() else None for value in fields[1:]]
        for key, value in zip(SITE_FIELDS + DPI_FIELDS, numbers):
            setattr(self, key, value)

    @property
    def sites_tested(self):
        return self.ok is not None and self.err is not None

    @property
    def dpi_tested(self):
        return self.dpi_ok is not None

    @property
    def tested(self):
        return self.sites_tested or self.dpi_tested

    @property
    def sites_total(self):
        return self.ok + self.err if self.sites_tested else 0

    @property
    def dpi_total(self):
        return (self.dpi_ok or 0) + (self.dpi_fail or 0) + (self.dpi_blocked or 0) if self.dpi_tested else 0

    @property
    def sites_share(self):
        """Доля открывшихся сайтов, None - не проверялось."""
        if not self.sites_tested:
            return None
        return self.ok / self.sites_total if self.sites_total else 0.0

    @property
    def freeze_share(self):
        """Доля проверок с замиранием на 16-20 КБ, None - не проверялось."""
        if not self.dpi_tested:
            return None
        return (self.dpi_blocked or 0) / self.dpi_total if self.dpi_total else 0.0

    def apply_result(self, values):
        """Строка @result теста: 5 чисел - сайты, 4 - замирание, 9 - оба теста."""
        if len(values) == 5:
            keys = SITE_FIELDS
        elif len(values) == 4:
            keys = DPI_FIELDS
        elif len(values) == 9:
            keys = SITE_FIELDS + DPI_FIELDS
        else:
            return False
        for key, value in zip(keys, values):
            setattr(self, key, value)
        return True

    def sites_text(self):
        return f"{self.ok}/{self.sites_total}" if self.sites_tested else "—"

    def freeze_text(self):
        return f"{self.dpi_blocked or 0}/{self.dpi_total}" if self.dpi_tested else "—"

    def sites_kind(self):
        """Цвет значка сайтов: от 90% зелёный, от 50% жёлтый, ниже красный, не проверялось - серый."""
        share = self.sites_share
        if share is None:
            return "badge-neutral"
        return "badge-good" if share >= 0.9 else ("badge-mid" if share >= 0.5 else "badge-bad")

    def freeze_kind(self):
        """Цвет значка замирания: без замираний зелёный, до трети жёлтый, больше красный, не проверялось - серый."""
        share = self.freeze_share
        if share is None:
            return "badge-neutral"
        if not self.dpi_blocked:
            return "badge-good"
        return "badge-mid" if share <= 1 / 3 else "badge-bad"

    def summary(self):
        """Подпись карточки лучшей стратегии: Сайты 36/36 · замирание 0/18."""
        return f"Сайты {self.sites_text()} · замирание {self.freeze_text()}"


def parse_strategies(text):
    return [Strategy(line, index) for index, line in enumerate(line for line in text.splitlines() if line)]


def sort_strategies(items):
    """Сначала больше открытых сайтов, при равенстве меньше замираний на 16-20 КБ, затем больше ответов ping.
    Стратегии без единого результата в конце, в порядке утилиты. Непроверенная часть считается худшей."""

    def key(item):
        if not item.tested:
            return (1, 0.0, 0.0, 0, item.index)
        sites = item.sites_share if item.sites_share is not None else -1.0
        freeze = item.freeze_share if item.freeze_share is not None else 2.0
        return (0, -sites, freeze, -(item.ping_ok or 0), item.index)

    return sorted(items, key=key)


def best_strategy(items):
    ranked = [item for item in sort_strategies(items) if item.tested]
    return ranked[0] if ranked else None


class UpgradeInfo:
    """Ответ zapret upgrade --check: строки ключ=значение, а если GitHub недоступен, код 1 и текст для человека."""

    def __init__(self, rc, text):
        self.values = {}
        self.messages = []
        for line in text.splitlines():
            key, sep, value = line.partition("=")
            if sep and key.isidentifier():
                self.values[key] = value.strip()
            elif line.strip():
                self.messages.append(line.strip())
        self.ok = rc == 0 and "newer" in self.values

    @property
    def newer(self):
        return self.ok and self.values.get("newer") == "1"

    @property
    def current(self):
        return self.values.get("current", "")

    @property
    def latest(self):
        return self.values.get("latest", "")

    @property
    def page(self):
        return self.values.get("page", "")

    @property
    def reason(self):
        return self.messages[-1] if self.messages else "Не удалось связаться с GitHub"


# так утилита отвечает, если обновлять нечего: тогда окно перезапускать не нужно
UPGRADE_UP_TO_DATE = "Установлена последняя версия"


def upgrade_installed(rc, lines):
    return rc == 0 and not any(UPGRADE_UP_TO_DATE in line for line in lines)


class Job:
    """Запущенная команда. Вывод приходит построчно: тест стратегий идёт минутами, и прогресс нужен сразу."""

    def __init__(self, argv, on_line, on_exit, dispatch):
        self.argv = argv
        self.on_line = on_line
        self.on_exit = on_exit
        self.dispatch = dispatch
        self.lines = []
        threading.Thread(target=self._run, daemon=True).start()

    def _run(self):
        try:
            process = subprocess.Popen(
                self.argv,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                errors="replace",
                bufsize=1,
            )
        except OSError as error:
            self.dispatch(self.on_exit, 127, [f"Не удалось запустить {self.argv[0]}: {error}"])
            return
        for line in process.stdout:
            line = line.rstrip("\n")
            self.lines.append(line)
            if self.on_line:
                self.dispatch(self.on_line, line)
        self.dispatch(self.on_exit, process.wait(), self.lines)


class Backend:
    def __init__(self, dispatch, home=None):
        self.dispatch = dispatch
        self.home = home or os.environ.get("ZAPRET_HOME") or os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
        self.zapret = os.path.join(self.home, "zapret")

    def _read(self, *args, timeout=20):
        result = subprocess.run(
            [self.zapret, *args],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            errors="replace",
            timeout=timeout,
        )
        return result.stdout

    # Чтение не требует прав и вызывается из рабочего потока

    def state(self):
        return State(self._read("state"))

    def strategies(self):
        return parse_strategies(self._read("list", "--tsv"))

    def domains(self):
        return [line.strip() for line in self._read("domains").splitlines() if line.strip()]

    def upgrade_check(self):
        """Есть ли новая версия приложения. Сетевой запрос без прав администратора."""
        result = subprocess.run(
            [self.zapret, "upgrade", "--check"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            errors="replace",
            timeout=60,
        )
        return UpgradeInfo(result.returncode, result.stdout)

    def fakes(self):
        active = {}
        files = []
        for line in self._read("fakes", "list").splitlines():
            key, _, value = line.partition("=")
            if key == "file":
                files.append(value)
            else:
                active[key] = value
        return active, files

    # Команды

    def spawn(self, args, root=True, on_line=None, on_exit=None):
        # pkexec очищает окружение и показывает системное окно пароля. От имени root (например, в проверках) он не нужен
        prefix = ["pkexec"] if root and os.geteuid() != 0 else []
        return Job([*prefix, self.zapret, *args], on_line, on_exit or (lambda rc, lines: None), self.dispatch)


def visible_lines(lines):
    """Вывод для человека: без служебных строк и пустых строк."""
    return [line for line in lines if line.strip() and not line.startswith("@")]


def last_message(lines, fallback=""):
    """Последняя строка для уведомления. Советы вида "выполните zapret next" в окне только мешают: там есть кнопки."""
    shown = [line for line in visible_lines(lines) if "zapret " not in line]
    return shown[-1].strip() if shown else fallback


def parse_diagnostics(lines):
    """Разбор zapret diag: секции разделены пустой строкой, [X] значит ошибку, [?] значит предупреждение."""
    sections = []
    current = []
    for line in lines + [""]:
        if line.strip():
            current.append(line.strip())
        elif current:
            level = "ok"
            if any(item.startswith("[X]") for item in current):
                level = "error"
            elif any(item.startswith("[?]") for item in current):
                level = "warning"
            cleaned = [item.replace("[X] ", "").replace("[?] ", "") for item in current]
            sections.append((level, cleaned[0], "\n".join(cleaned[1:])))
            current = []
    return sections
