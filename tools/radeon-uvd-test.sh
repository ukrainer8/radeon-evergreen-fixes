#!/bin/bash
# Одноразовий тест патченого radeon (uvd_v1_0 retry patch) на S3-resume.
# Запускається лише з kernel cmdline "radeon-uvd-test" (див. radeon-uvd-test.service).
# Дизайн: одне тестове завантаження, жодного rmmod (fbdev-емуляція не знімається
# вживу), жодних файлів стану в /var/lib, жодних слідів у /lib/modules.
# Вихід з будь-якої точки = перезавантаження в нормальний режим (trap EXIT).
set -u
LOG=/var/log/radeon-uvd-test.log
PATCHED_KO=/usr/local/lib/radeon-uvd/radeon-patched.ko
EXPECTED_SRCVERSION=C4D7701B2C536EEF74BC864   # modinfo -F srcversion патченого модуля
CYCLES=6

# Не працювати поза тестовим режимом (захист від ручного запуску в GUI).
grep -q 'radeon-uvd-test' /proc/cmdline || exit 0

exec 9>/run/radeon-uvd-test.lock
# Другий екземпляр виходить ТИХО, ДО встановлення trap — інакше його вихід
# перезавантажив би машину посеред працюючого тесту.
flock -n 9 || exit 0

# Контракт «не застрягнути»: будь-який подальший вихід — ребут у нормальний режим.
trap 'sync; systemctl reboot' EXIT
exec > >(tee -a "$LOG") 2>&1

log() { echo "[$(date '+%F %T')] $*"; }

OK=0; FAIL=0; UNKNOWN=0
log "===== radeon-uvd-test start (kernel $(uname -r)) ====="

# Захист від drift: модуль зібраний під конкретне ядро, GRUB-пункт пінить його ж.
if [ "$(uname -r)" != "7.0.0-38-generic" ]; then
    log "ERROR: ядро $(uname -r) != 7.0.0-38-generic — модуль не підходить, тест скасовано"
    exit 0
fi
if [ ! -f "$PATCHED_KO" ]; then
    log "ERROR: $PATCHED_KO не знайдено — тест скасовано"
    exit 0
fi

sleep 15

# Залежності: insmod їх не розв'язує. Беремо dep-ланцюг stock-модуля,
# відсікаючи сам radeon за ім'ям (не за позицією рядка).
DEPS=$(modprobe --show-depends radeon 2>/dev/null | awk '$1=="insmod"{print $2}' \
       | while IFS= read -r p; do b="${p##*/}"; b="${b%%.ko*}"; [ "$b" != "radeon" ] && echo "$b"; done)
log "deps for radeon: $(echo $DEPS)"
[ -n "$DEPS" ] && modprobe -a $DEPS 2>&1

if ! lsmod | grep -q '^radeon'; then
    insmod "$PATCHED_KO" 2>&1 || log "ERROR: insmod failed (rc=$?)"
fi

if ! lsmod | grep -q '^radeon'; then
    log "ERROR: radeon не завантажився — тест скасовано"
    exit 0
fi

# ПОЗИТИВНА перевірка ідентичності: завантажений модуль зобов'язаний бути патченим.
NOW_SRC=$(cat /sys/module/radeon/srcversion 2>/dev/null)
if [ "$NOW_SRC" != "$EXPECTED_SRCVERSION" ]; then
    log "ERROR: srcversion=$NOW_SRC != очікуваного $EXPECTED_SRCVERSION — це НЕ патчений модуль, тест недійсний"
    exit 0
fi
log "module identity OK: patched radeon srcversion=$NOW_SRC"
sleep 3

for i in $(seq 1 "$CYCLES"); do
    n=$(dmesg | wc -l)
    log "[patched] cycle $i/$CYCLES: suspend (rtcwake -m mem -s 25)"
    rtcwake -m mem -s 25 2>&1
    sleep 5
    seg=$(dmesg | tail -n +$((n + 1)))
    printf '%s\n' "$seg"
    if printf '%s\n' "$seg" | grep -q "UVD initialized successfully"; then
        OK=$((OK + 1)); log "[patched] cycle $i: OK"
    elif printf '%s\n' "$seg" | grep -qE "ring 5 test failed|failed initializing UVD"; then
        FAIL=$((FAIL + 1)); log "[patched] cycle $i: FAIL (ring 5)"
    else
        UNKNOWN=$((UNKNOWN + 1)); log "[patched] cycle $i: UNKNOWN (no UVD verdict; можливо переповнення dmesg буфера)"
    fi
done

log "===== SUMMARY: patched ok=$OK/$CYCLES fail=$FAIL unknown=$UNKNOWN (baseline зібрано раніше: 7 серій, ~50% OK) ====="
log "--- drm/uvd рядки цього boot (ретраї патча) ---"
dmesg | grep -iE 'uvd|ring 5' | tail -80
log "===== radeon-uvd-test end, rebooting to normal mode ====="
exit 0  # trap EXIT зробить reboot
