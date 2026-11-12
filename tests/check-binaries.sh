#!/bin/bash
# check-binaries.sh BIN_DIR UNSTRIPPED_DIR REPORT_FILE
#
# Verifies that every binary in BIN_DIR is a static 32-bit ARM EABI5
# soft-float executable for ARMv5TE(J) without ARMv6+/VFP/NEON code paths
# that could be reached on an ARM926EJ-S. Symbol based checks (Thumb code,
# which function contains an instruction) use the unstripped copies, after
# checking that their code is identical to the shipped binaries.
set -uo pipefail

BIN_DIR=$1
UNSTRIPPED=$2
REPORT=$3
CROSS=${CROSS_PREFIX:-arm-buildroot-linux-musleabi-}
fail=0

# Instructions that do not exist on ARMv5TE(J). A hit is only accepted inside
# the musl functions listed in ALLOWED_FUNCS:
#  - __a_barrier_v6/v7, __a_cas_v6/v7, __a_gettp_cp15: atomics/TLS variants
#    that musl selects at start-up from AT_HWCAP and the kernel user-helper
#    version; on ARMv5 the kernel user helpers (__kuser_*) are used instead.
#  - setjmp/longjmp: save/restore VFP d8-d15 only after "tst r1, #64"
#    (HWCAP_VFP) on __hwcap, i.e. only if the kernel reports a VFP unit.
V6PLUS='^(ldrex|strex|ldrexd|strexd|ldrexb|strexb|ldrexh|strexh|clrex|dmb|dsb|isb|rev|rev16|revsh|rbit|uxtb|uxth|sxtb|sxth|uxtab|uxtah|sxtab|sxtah|uxtb16|sxtb16|movw|movt|ubfx|sbfx|bfi|bfc|sel|ssat|usat|ssat16|usat16|pkhbt|pkhtb|smlad|smladx|smlsd|smuad|smusd|umaal|udiv|sdiv|wfi|wfe|sev|yield|cpsid|cpsie|srs|rfe|setend|v[a-z0-9.]+|cbz|cbnz|it[te]*)(eq|ne|cs|cc|hs|lo|mi|pl|vs|vc|hi|ls|ge|lt|gt|le|al)?$'
ALLOWED_FUNCS='^(__a_barrier_v6|__a_barrier_v7|__a_cas_v6|__a_cas_v7|__a_gettp_cp15|__setjmp|_setjmp|setjmp|_longjmp|longjmp|siglongjmp|sigsetjmp)$'

exec > >(tee "$REPORT") 2>&1

echo "Binary verification ($(date -u +%Y-%m-%dT%H:%M:%SZ))"
echo "toolchain: $(cat /opt/toolchain/TOOLCHAIN_NAME 2>/dev/null)"
echo

for b in "$BIN_DIR"/*; do
    n=$(basename "$b")
    echo "=================================================================="
    echo "$n  ($(stat -c %s "$b") bytes)"
    echo "------------------------------------------------------------------"
    echo "file: $(file -b "$b")"
    hdr=$(readelf -h "$b")
    echo "$hdr" | grep -E "Class|Data|Machine|Flags|Type:"
    echo "ARM attributes (readelf -A):"
    attrs=$(readelf -A "$b")
    echo "$attrs" | sed 's/^/    /'

    echo "$hdr" | grep -q "Class:.*ELF32" || { echo "FAIL: not ELF32"; fail=1; }
    echo "$hdr" | grep -q "Machine:.*ARM" || { echo "FAIL: not ARM"; fail=1; }
    echo "$hdr" | grep -q "Version5 EABI" || { echo "FAIL: not EABI5"; fail=1; }
    echo "$hdr" | grep -q "soft-float ABI" || { echo "FAIL: soft-float ABI flag missing"; fail=1; }
    echo "$hdr" | grep -qi "hard-float" && { echo "FAIL: hard-float"; fail=1; }
    echo "$attrs" | grep -qE "Tag_CPU_arch: v5TEJ?$" || { echo "FAIL: Tag_CPU_arch is not v5TE/v5TEJ"; fail=1; }

    u=$UNSTRIPPED/$n
    if [ ! -f "$u" ]; then echo "FAIL: no unstripped copy $u"; fail=1; continue; fi
    ${CROSS}objcopy -O binary -j .text "$b" /tmp/text.stripped
    ${CROSS}objcopy -O binary -j .text "$u" /tmp/text.unstripped
    t1=$(sha256sum < /tmp/text.stripped | cut -c1-16)
    t2=$(sha256sum < /tmp/text.unstripped | cut -c1-16)
    if [ "$t1" = "$t2" ]; then echo ".text identical to the unstripped copy (sha256 $t1...)"
    else echo "FAIL: .text differs from the unstripped copy"; fail=1; fi

    # Thumb code would be marked by \$t mapping symbols. ARM926EJ-S only has
    # Thumb-1; any Thumb code at all is rejected here.
    nthumb=$(readelf -sW "$u" | awk '$8 ~ /^\$t(\.|$)/' | wc -l)
    if [ "$nthumb" = 0 ]; then
        echo "Thumb code: none (no \$t mapping symbols; all code is ARM/A32)"
        if echo "$attrs" | grep -q "Tag_THUMB_ISA_use: Thumb-2"; then
            echo "    note: Tag_THUMB_ISA_use=Thumb-2 is inherited from musl's atomics.lo, whose"
            echo "    ARMv6/v7 dispatch routines are assembled with .arch armv7-a (ARM mode)."
        fi
    else
        echo "FAIL: $nthumb Thumb mapping symbols"; fail=1
    fi
    echo "$attrs" | grep -qE "Tag_(FP_arch|VFP_arch|Advanced_SIMD_arch|MPextension_use|DIV_use: Allowed)" && { echo "FAIL: FP/NEON/MP/DIV attribute present"; fail=1; }
    echo "$attrs" | grep -q "Tag_ABI_VFP_args: VFP registers" && { echo "FAIL: VFP argument passing"; fail=1; }

    if readelf -l "$b" | grep -q "INTERP"; then
        echo "FAIL: has a program interpreter (dynamically linked)"; fail=1
    else
        echo "program interpreter: none (static)"
    fi
    needed=$(readelf -d "$b" 2>/dev/null | grep NEEDED || true)
    if [ -n "$needed" ]; then echo "FAIL: NEEDED entries:"; echo "$needed"; fail=1
    else echo "shared library dependencies (DT_NEEDED): none"; fi

    # Disassembly scan (ARM and Thumb mapping symbols are honoured by objdump).
    hits=$(${CROSS}objdump -d --no-show-raw-insn "$u" | awk -v re="$V6PLUS" '
        /^[0-9a-f]+ <.*>:$/ { fn=$2; gsub(/[<>:]/, "", fn); next }
        /^ *[0-9a-f]+:\t/ { split($0, a, "\t"); m=a[2]; sub(/[ \t].*/, "", m);
                            # strip condition codes / .n .w suffixes for the match
                            base=m; sub(/\.(n|w)$/, "", base);
                            if (base ~ re) cnt[fn]++ }
        END { for (f in cnt) printf "%s %d\n", f, cnt[f] }' | sort)
    bad=""
    if [ -n "$hits" ]; then
        echo "ARMv6+ instructions found in (function count):"
        while read -r f c; do
            if [[ $f =~ $ALLOWED_FUNCS ]]; then
                echo "    $f $c   (musl, guarded by a run-time AT_HWCAP check)"
            else
                echo "    $f $c   NOT ALLOWED"; bad=1
            fi
        done <<< "$hits"
    else
        echo "ARMv6+ instructions: none"
    fi
    [ -n "$bad" ] && { echo "FAIL: ARMv6+ instructions outside musl dispatch code"; fail=1; }
    echo "strings check: $(strings "$b" | grep -c '/tmp/onvif' ) references to /tmp/onvif"
    echo
done

if [ "$fail" = 0 ]; then echo "RESULT: PASS"; else echo "RESULT: FAIL"; fi
exit $fail
