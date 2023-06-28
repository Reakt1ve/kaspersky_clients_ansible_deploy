#! /bin/bash


function check_input_args() {
	opts=$(_getopts)

	set -- $(echo $opts | tr ';' ' ')
	count_opts="$#"

	while (( "$#" )); do
		case "$1" in
			-h | --help )
				print_help_screen
			;;
			-l | --limit )
				if [[ ! -z $2 ]]; then
					LIST_HOSTS="--limit $2"
					shift 2
				else
					return 1
				fi
			;;
			-t | --tag )
				if [[ ! -z $2 ]]; then
					TAG="--tags $2"
					shift 2
				else
					return 1
				fi
			;;
			-- )
				return 1
			;;
			* )
			;;
		esac
	done

	return 0
}

function _getopts() {
	local n_index=${#BASH_ARGV[@]}
	declare -a list_opt
	let list_opt_idx=0

	for i in $(seq ${n_index} -1 0); do
		list_opt[$list_opt_idx]=${BASH_ARGV[$i]}
		(( list_opt_idx++ ))
	done

	printf '%s;' "${list_opt[@]}"
}

function print_help_screen(){
cat << EOF
Использование: ./init_kesl_ansible.sh <options>

Options:
	-h, --help
		Отобразить окно помощи и выйти

	-l, --limit
		Указать задействованные узлов

	-t, --tag
		Запустить конкретную задачу
EOF

	exit 0
}

function print_invalid_input_screen() {
	cat << EOF
использование: install-kasper.sh [--help| -h][--limit <list_hosts>| -l <list_hosts>][--tag <tag_name>| -t <tag_name>]
Запустите скрипт с верными аргументами
EOF
}

function print_no_data_screen() {
	cat << EOF
Отсутствуют файлы данный для работы ansible
EOF
}

function print_ansible_run_error_screen() {
	cat << EOF
Произвошла ошибка во время работы Ansible
EOF
}

### $1 Результат выполнения ansible-playbook
function check_SSH_conn() {
	OLD_IFS=$IFS
	IFS=$'\n'
	for str in $1; do
		host=$(echo "$str" | grep "UNREACHABLE!" | cut -d ']' -f1 | cut -d '[' -f2 | cut -d '.' -f1)
		if [[ ! -z $host ]]; then
			echo "$host" >> $UNREACHABLE_HOSTS_LOG
		fi
	done
	IFS=$OLD_IFS
}

function check_Ansible_conf() {
	if [[ ! -d /etc/ansible ]]; then
		return 1
	fi

	if [[ ! -f ${ANSIBLE_DATA_DIR_SRC}/${PLAYBOOK_FILE} ]]; then
		return 1
	fi
	cp -a ${ANSIBLE_DATA_DIR_SRC}/${PLAYBOOK_FILE} ${PLAYBOOK_DIR}

	if [[ ! -f ${ANSIBLE_DATA_DIR_SRC}/hosts ]]; then
		return 1
	fi
	cp -a ${ANSIBLE_DATA_DIR_SRC}/hosts ${ANSIBLE_DIR}

	if [[ ! -f ${ANSIBLE_DATA_DIR_SRC}/ansible.cfg ]]; then
		return 1
	fi
	cp -a ${ANSIBLE_DATA_DIR_SRC}/ansible.cfg ${ANSIBLE_DIR}

	if [[ ! -d ${ANSIBLE_DATA_DIR_SRC}/group_vars ]]; then
		return 1
	fi
	cp -a ${ANSIBLE_DATA_DIR_SRC}/group_vars ${ANSIBLE_DIR}

	return 0
}

### Дебаг режим
#set -x

### Проверка пользователя
if [[ $(whoami) != "root" ]]; then
	echo "Вы должны быть пользователем root, чтобы запустить скрипт"
	exit -1
fi

check_input_args
exit_code=$?
if [ $exit_code -ne 0 ]; then
	print_invalid_input_screen
	exit -1
fi

UNREACHABLE_HOSTS_LOG=/var/log/ansible/unreachable_hosts.log
ANSIBLE_DIR=/etc/ansible
PLAYBOOK_FILE=kesl.yml
PLAYBOOK_RETRY=${PLAYBOOK_FILE//yml/retry}
PLAYBOOK_DIR=${ANSIBLE_DIR}/playbooks
RETRY_FILE_PATH=${PLAYBOOK_DIR}/${PLAYBOOK_RETRY}
ANSIBLE_DATA_DIR_SRC=$(pwd)/ansible-data

### Удаление файла повтора
rm -rf $RETRY_FILE_PATH >/dev/null

### Зачистка ошибочного лога от ansible
rm -rf /var/log/ansible/error_hosts.log >/dev/null

### Создание лог папки
mkdir -p /var/log/ansible

> $UNREACHABLE_HOSTS_LOG

### Развертывание пользовательских файлов kesl для ansible
check_Ansible_conf
exit_code=$?
if [ $exit_code -ne 0 ]; then
	print_no_data_screen
	exit -1
fi

### Переход в рабочую директорию
cd ${ANSIBLE_DIR}/playbooks

### Запуск ansible playbook
ansible_result=$(ansible-playbook "$PLAYBOOK_FILE" $LIST_HOSTS $TAG | tee /dev/tty)
exit_code=$?
if [ $exit_code -ne 0 ]; then
	print_ansible_run_error_screen
	exit -1
fi

### Проверка недоступных хостов
check_SSH_conn "$ansible_result"

while true; do
	if [[ ! -f ${RETRY_FILE_PATH} ]]; then
		break
	fi

	echo "Повторить запуск для необработанных хостов(y/N)?"
	read user_asw
	case "$user_asw" in
		Y|y|Д|д|Yes|yes|Да|да)
			cat ${RETRY_FILE_PATH} > active.retry
			rm -r ${RETRY_FILE_PATH}
			ansible_result=$(ansible-playbook "$PLAYBOOK_FILE" --limit @active.retry | tee /dev/tty)
			check_SSH_conn "$ansible_result"
			rm -r active.retry
		;;
		N|n|Н|н|No|no|Нет|нет)
			rm -r ${RETRY_FILE_PATH}
			echo "Завершение скрипта"
			break
		;;
		*)
			echo "Неверное значение. Повторите ввод заново"
		;;
	esac
done
