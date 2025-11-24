#!/usr/bin/env bash
#
# Описание
#
# Генерирует модуль на языке GDScript с информацией для контроля
# версий в системе git. Использовать для проектов GoDot Engine.

GDSCRIPT_FILE="commit.gd"
HEAD="$(git rev-parse --abbrev-ref HEAD) $(git rev-parse --short HEAD) $(git log -1 --format=%cd)"
echo "extends Node" > ${GDSCRIPT_FILE}
echo "# Файл сгенерирован автоматически! Не изменять вручную!" >> ${GDSCRIPT_FILE}
echo "const VCS_HEAD = '${HEAD}'" >> ${GDSCRIPT_FILE}