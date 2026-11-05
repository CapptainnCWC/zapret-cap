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


class Strategy:
    """Строка zapret list --tsv: имя и итоги последнего обычного теста."""

    def __init__(self, line):
        fields = (line.split("\t") + [""] * 6)[:6]
        self.name = fields[0]
        self.ok, self.err, self.unsup, self.ping_ok, self.ping_fail = [
            int(value) if value.isdigit() else None for value in fields[1:]
        ]

    @property
    def tested(self):
        return self.ok is not None


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
        return [Strategy(line) for line in self._read("list", "--tsv").splitlines() if line]

    def domains(self):
        return [line.strip() for line in self._read("domains").splitlines() if line.strip()]

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
