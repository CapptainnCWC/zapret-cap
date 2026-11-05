# Главное меню: перенос service.bat и новые пункты для смены стратегии и доменов

menu_header()
{
	local current
	current="$(state_get current)"
	game_load
	[ -t 1 ] && clear
	echo
	printf '  %sZAPRET CAP %s%s (стратегии Flowseal %s)\n' "$C_BOLD" "$(cap_version)" "$C_OFF" "$(flowseal_version)"
	if engine_running; then
		printf '  %sОбход работает:%s %s\n' "$C_GREEN" "$C_OFF" "$(state_get running_strategy "$current")"
	else
		printf '  %sОбход выключен%s\n' "$C_RED" "$C_OFF"
	fi
	if [ -f "$RUN_DIR/update-available" ]; then
		printf '  %sВышли новые стратегии Flowseal: %s%s\n' "$C_YELLOW" "$(cat "$RUN_DIR/update-available")" "$C_OFF"
	fi
	echo "  ----------------------------------------"
}

menu_main()
{
	local choice
	while :; do
		menu_header
		cat <<EOF

  :: ПОДБОР СТРАТЕГИИ
     1. Найти лучшую стратегию (тест)
     2. Не работает - следующая стратегия
     3. Не работает - подобрать автоматически

  :: ОБХОД
     4. Выбрать стратегию и включить
     5. Выключить обход
     6. Статус
     7. Автозапуск          [$(autostart_status)]

  :: ДОМЕНЫ
     8. Добавить домен
     9. Убрать домен
    10. Показать список

  :: НАСТРОЙКИ
    11. Фильтр игр          [$GAME_FILTER_STATUS]
    12. Режим IPSet         [$(ipset_status)]
    13. Заменить активные фейки
    14. Автопроверка обновлений [$(update_check_status)]

  :: ОБНОВЛЕНИЯ
    15. Обновить список IPSet
    16. Обновить файл hosts
    17. Проверить обновления

  :: ПОМОЩЬ
    18. Диагностика проблем

  ----------------------------------------
     0. Выход

EOF
		read -r -p "  Выберите пункт (0-18): " choice || return 0
		echo
		case "$choice" in
			1) tests_dialog; pause ;;
			2) switch_next; pause ;;
			3) switch_auto; pause ;;
			4) switch_use; pause ;;
			5) service_remove; pause ;;
			6) show_status; pause ;;
			7)
				if autostart_wanted; then autostart_set off; else autostart_set on; fi
				pause
				;;
			8) domain_add; pause ;;
			9)
				local domains
				read -r -a domains -p "Какой домен убрать? " || continue
				[ ${#domains[@]} -gt 0 ] && domain_remove "${domains[@]}"
				pause
				;;
			10) domain_list; pause ;;
			11) game_menu ;;
			12) ipset_cli next; pause ;;
			13) fakes_menu ;;
			14)
				if [ -f "$(update_check_flag)" ]; then update_check_cli off; else update_check_cli on; fi
				pause
				;;
			15) ipset_update; pause ;;
			16) hosts_update; pause ;;
			17) update_check_now; pause ;;
			18) diagnostics; pause ;;
			0) return 0 ;;
			*) ;;
		esac
	done
}
