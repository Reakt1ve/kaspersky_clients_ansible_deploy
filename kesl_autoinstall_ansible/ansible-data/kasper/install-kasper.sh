#! /bin/bash

### Проверка пользователя
if [[ $(whoami) != "root" ]]; then
	echo "Вы должны быть пользователем root, чтобы запустить скрипт"
	exit -1
fi

### Основные параметры
HOSTIP=$(ip a | grep inet | grep -v inet6 | grep -v 127.0.0.1 | cut -f1 -d '/' | tr -d ' ' | cut -d 't' -f2)
WORKDIR=/usr/doc/ansible/kesl/kasper
INSTALL_DIR_KESL=/opt/kaspersky/kesl/bin
KESL_DIST=path
CSV_PARAM_FILE=$WORKDIR/param_file.csv
INI_CONFIG_SAMPLE=$WORKDIR/autoinstall.ini.sample

### Логические параметры
IS_PREINSTALL_PARAM_ACTIVE=false
IS_PRESERVE_INSTALL_ACTIVE=false

function _getopts(){
	local n_index=${#BASH_ARGV[@]}
	declare -a list_opt
	let list_opt_idx=0

	if [[ "$n_index" > "0" ]]; then
		for i in $(seq ${n_index} -1 0); do
			list_opt[$list_opt_idx]=${BASH_ARGV[$i]}
			(( list_opt_idx++ ))
		done

		printf '%s;' "${list_opt[@]}"
	else
		echo "empty"
	fi
}

function check_input_args(){
	opts=$(_getopts)
	if [[ "$opts" == "empty" ]]; then
		return 1
	fi

	set -- $(echo $opts | tr ';' ' ')
	count_opts="$#"

	while (( "$#" )); do
		case "$1" in
			-h | --help )
				print_help_screen
			;;
			-d | --kesl-dist )
				if [[ ! -z $2 ]]; then
					KESL_DIST=$2
					shift 2
				else
					return 1
				fi
			;;
			-p | --preinstall )
				input_args_bonding "preinstall"
				local exit_code=$?
				if [ $exit_code -ne 0 ]; then
					return 1
				fi

				IS_PREINSTALL_PARAM_ACTIVE=true
				if [[ "$count_opts" > "1" ]]; then
					shift
				else
					return 1
				fi
			;;
			-s | --preserve )
				input_args_bonding "preserve"
				local exit_code=$?
				if [ $exit_code -ne 0 ]; then
					return 1
				fi

				IS_PRESERVE_INSTALL_ACTIVE=true
				if [[ "$count_opts" > "1" ]]; then
					shift
				else
					return 1
				fi
			;;
			-- )
				return 1
			;;
			* )
				return 1
			;;
		esac
	done

	return 0
}

function input_args_bonding() {
	local input_param="$1"

	if echo "$input_param" | grep "preinstall" >/dev/null; then
		if echo "$IS_PRESERVE_INSTALL_ACTIVE" | grep "true" >/dev/null; then
			return 1
		fi

		return 0
	fi

	if echo "$input_param" | grep "preserve" >/dev/null; then
		if echo "$IS_PREINSTALL_PARAM_ACTIVE" | grep "true" >/dev/null; then
			return 1
		fi

		return 0
	fi
}

function print_help_screen() {
cat << EOF
Использвание: ./install-kasper.sh <options>

Options:
	-h, --help
		Отобразить окно помощи и выйти

	-d, --kesl-dist
		Указать путь (абсолютный) к дистрибутиву kesl-elbrus

	-p, --preinstall
		Параметр сообщает, что нужно удалить предыдущую версию антивируса

	-s, --preserve
		Параметр сообщает, что нужно сохранить предыдущую версию антивируса

EOF

	exit 0
}

function print_invalid_input_screen(){
cat << EOF
использование: install-kasper.sh [--help| -h][--kesl-dist <path>| -d <path>][--preinstall| -p || --preserve| -s]
Запустите скрипт с верными аргументами
EOF
}

### $1 тип исключения
function print_error_msg(){
	case $1 in
		"dpkg exception" )
			echo "Произошла ошибка во время установки пакета"
		;;
		"kesl exception" )
			echo "Произошла ошибка при работе скрипта kesl-install.pl"
		;;
		"args exception" )
			echo "Неверно переданы аргументы"
		;;
		"purge exception" )
			echo "Произошла ошибка во время удаления пакета"
		;;
		* )
			echo "Неизвестная ошибка"
		;;
	esac

	exit -1
}

function check_antivir_state(){
	if  dpkg -l | grep "^ii" | grep kesl-astra >/dev/null; then
		local purge_answer=""
		while true; do
			if echo "$IS_PRESERVE_INSTALL_ACTIVE" | grep "true" >/dev/null; then
				purge_answer="no"
			elif echo "$IS_PREINSTALL_PARAM_ACTIVE" | grep "true" >/dev/null; then
				purge_answer="yes"
			else
				echo "На текущей машине установлен/и настроен антивирус Kaspersky. Желаете его удалить? [yes|no]"
				read purge_answer
			fi

			case "$purge_answer" in
				yes|y|Y)
					purge_current_kasper
					break
				;;
				no|n|N)
					echo "Установка завершена, т.к. на машине уже установлен антивирус."
					echo "Примечание: для установки новой версии kaspersky либо удалите предыдущую самостоятельно, либо при запросе на удаление автоматически напишите [yes]"
					exit 1
				;;
				*)
					echo "Неверное значение. Повторите попытку"
				;;
			esac
		done

	fi
}

function purge_current_kasper(){
	echo "Удаление текущей версии антивируса.."

	dpkg -l | grep kesl | awk '{print $2}' | xargs -n1 apt-get purge -y
	if [[ "$?" == "100" ]]; then
		echo "Пакет антивируса отсутствует на машине"
	elif [[ "$?" == "1" ]]; then
		echo "Warning: при удалении имеется остаточная информация"
	elif [[ "$?" == "0" ]]; then
		echo "Удаление прошло успешно"
	else
		print_error_msg "purge exception"
	fi

	rm -rf /var/opt/kaspersky/

	sync; echo 3 > /proc/sys/vm/drop_caches
}

### $1 CSV файл с параметрами
### $2 Изменяемый файл
function edit_file_from_CSV(){
	update_ip=$(grep -m 1 "$HOSTIP" $1 | cut -d ',' -f2)
	sed -i s!COLUMN#AVZUPDATE#!${update_ip}!g $2
}

### Проверка входных параметров скрипта
check_input_args
exit_code=$?
if [ $exit_code -ne 0 ]; then
	print_invalid_input_screen
	exit -1
fi

### Проверка существования установленного антивируса
check_antivir_state

CHANGEABLE_FILE=$WORKDIR/autoinstall.ini

### Создание установочного ini файла Kaspersky
cat $INI_CONFIG_SAMPLE > $CHANGEABLE_FILE

### Редактирование установочного ini файла для Kaspersky
edit_file_from_CSV $CSV_PARAM_FILE $CHANGEABLE_FILE

### распаковка kesl
dpkg -i --force-overwrite $KESL_DIST
if [[ ! "$?" == "0" ]]; then
	print_error_msg "dpkg exception"
fi

### Смена пути на установочную директорию Kaspersky
cd $INSTALL_DIR_KESL

### Установка kesl
./kesl-setup.pl --autoinstall=$CHANGEABLE_FILE
if [[ ! "$?" == "0" ]]; then
	print_error_msg "kesl exception"
fi

if service kesl-supervisor status | grep "active (running)" >/dev/null; then
	echo "Антивирус успешно установлен и активирован. Mission acomplished!!!"
else
	echo "Антивирус успешно установлен и активирован, но запустился с ошибкой."
	echo "Попробуйте перезапустить сервис командой: service kesl-supervisor restart"
	echo "Затем выполните команду: service kesl-supervisor status"
	echo "Если статус задачи сохраняет состояние failed или dead, запустите скрипт заново с дополнительным параметром --preinstall"
	echo "Если ошибка все равно сохраняется, то обратитесь к ответственному администратору безопасности"
fi

rm -rf $CHANGEABLE_FILE

exit 0
