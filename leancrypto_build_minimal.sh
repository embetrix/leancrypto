# Minimal leancrypto build: ML-DSA-65 + ML-KEM-768 only, static library only,
# lowest-footprint libleancrypto.a:
#   --buildtype=minsize   : optimize for size (-Os), no debug info
#   -Ddisable-asm=true    : portable C only, no AVX2/assembler backends
#                           (smaller .a, but slower crypto operations)
#   strip/objcopy at the end: remove leftover debug + LTO bitcode sections
# Requires the local patches on master (kyber_type.h, dilithium_type.h,
# dilithium_common_api.c, ml-dsa/tests/meson.build).
# Every feature option is pinned explicitly so upstream default changes
# cannot silently re-enable anything.
#
# Cross-compilation (e.g. Yocto SDK for aarch64):
#   Setting $CC alone is NOT enough - meson needs a cross file, otherwise it
#   detects the build host (x86_64) and feeds -mavx2 to the ARM compiler.
#   Usage:  ./leancrypto_build_minimal.sh [meson-cross-file]
#   With a sourced Yocto SDK environment the cross file is auto-detected.

MESON=meson
CROSS_ARGS=""
if [ -n "$1" ]; then
	CROSS_ARGS="--cross-file $1"
elif [ -n "$OECORE_NATIVE_SYSROOT" ]; then
	cf=$(find "$OECORE_NATIVE_SYSROOT/usr/share/meson" -name '*meson.cross' 2>/dev/null | head -1)
	if [ -z "$cf" ]; then
		echo "Yocto SDK env detected but no meson cross file found - aborting" >&2
		echo "(install nativesdk-meson in the SDK or pass the cross file as argument)" >&2
		exit 1
	fi
	# Some SDKs generate the cross file with the SDK-host arch (x86_64) in
	# [host_machine] instead of the target arch. leancrypto selects its
	# assembler backends from host_machine.cpu_family(), so a wrong value
	# makes it feed -mavx2 to the ARM compiler. Use a corrected copy.
	sed -e "s|^cpu_family = .*|cpu_family = '${OECORE_TARGET_ARCH}'|" \
	    -e "s|^cpu = .*|cpu = '${OECORE_TARGET_ARCH}'|" \
	    "$cf" > /tmp/lc-fixed.cross
	CROSS_ARGS="--cross-file /tmp/lc-fixed.cross"
	nf="$OECORE_NATIVE_SYSROOT/usr/share/meson/meson.native"
	[ -f "$nf" ] && CROSS_ARGS="$CROSS_ARGS --native-file $nf"
	# The SDK's "meson" is a wrapper that appends its own (uncorrected)
	# cross file AFTER our arguments - and the last cross file wins.
	# Bypass it and call meson.real directly.
	[ -x "$OECORE_NATIVE_SYSROOT/usr/bin/meson.real" ] && \
		MESON="$OECORE_NATIVE_SYSROOT/usr/bin/meson.real"
fi
echo "meson: $MESON"
echo "meson cross args: ${CROSS_ARGS:-<none, native build>}"

rm -rf build
# CC/CXX/... unset for meson only: the Yocto env exports them pointing at the
# cross compiler, which meson would misinterpret as the *native* compiler.
# All cross tools are specified in the cross file instead.
env -u CC -u CXX -u CPP -u LD -u AR -u NM -u STRIP -u OBJCOPY -u RANLIB \
$MESON setup build $CROSS_ARGS --default-library=static --buildtype=minsize \
  `# --- enabled: the two algorithms ---` \
  -Dkyber_768=enabled -Ddilithium_65=enabled \
  -Ddilithium_keygen=enabled -Ddilithium_siggen=enabled -Ddilithium_sigver=enabled \
  `# --- enabled: their hard dependencies ---` \
  `# sha3: required by ML-DSA and ML-KEM; kmac: ML-KEM SP800-108 KDF;` \
  `# xdrbg: SHAKE-based DRNG backing lc_seeded_rng (key generation)` \
  -Dsha3=enabled -Dkmac=enabled -Dxdrbg=enabled \
  -Denable_selftests=enabled -Dseedsource=builtin \
  `# --- disabled: all other ML-KEM / ML-DSA parameter sets and hybrids ---` \
  -Dkyber_1024=disabled -Dkyber_512=disabled -Dkyber_x25519=disabled -Dkyber_x448=disabled \
  -Ddilithium_87=disabled -Ddilithium_44=disabled -Ddilithium_ed25519=disabled -Ddilithium_ed448=disabled \
  `# --- disabled: other PQC algorithms ---` \
  -Dbike_5=disabled -Dbike_3=disabled -Dbike_1=disabled \
  -Dhqc_256=disabled -Dhqc_192=disabled -Dhqc_128=disabled \
  -Dsphincs_shake_256s=disabled -Dsphincs_shake_256f=disabled \
  -Dsphincs_shake_192s=disabled -Dsphincs_shake_192f=disabled \
  -Dsphincs_shake_128s=disabled -Dsphincs_shake_128f=disabled \
  -Dslh_dsa_ascon_128s=disabled -Dslh_dsa_ascon_128f=disabled \
  `# --- disabled: hashes, symmetric ciphers, MAC/KDF/DRNG, OTP ---` \
  -Dsha2-256=disabled -Dsha2-512=disabled -Dascon=disabled -Dascon_keccak=disabled \
  -Daes_block=disabled -Daes_ecb=disabled -Daes_cbc=disabled -Daes_ctr=disabled \
  -Daes_kw=disabled -Daes_gcm=disabled -Daes_xts=disabled \
  -Dchacha20=disabled -Dchacha20poly1305=disabled -Dchacha20_drng=disabled \
  -Dhmac=disabled -Dhkdf=disabled -Dkdf_ctr=disabled -Dkdf_fb=disabled \
  -Dkdf_dpi=disabled -Dpbkdf2=disabled -Dhash_crypt=disabled \
  -Ddrbg_hash=disabled -Ddrbg_hmac=disabled -Ddrbg_ctr=disabled \
  -Dkmac_drng=disabled -Dcshake_drng=disabled \
  -Dhotp=disabled -Dtotp=disabled \
  `# --- disabled: certificate / PKI stack ---` \
  -Dx509_parser=disabled -Dx509_csr_parser=disabled \
  -Dx509_generator=disabled -Dx509_csr_generator=disabled \
  -Dpkcs7_parser=disabled -Dpkcs7_generator=disabled \
  -Dpkcs8_parser=disabled -Dpkcs8_generator=disabled \
  -Dsbsigntools=disabled \
  `# --- disabled: misc ---` \
  `# small_stack: <=2KB stack use, large buffers on heap (OP-TEE TA stacks are tiny)` \
  `# secure_execution stays disabled: Linux-only prctl speculation control, not available in OP-TEE` \
  -Defi=disabled -Dsecure_execution=disabled -Dsmall_stack=enabled \
  -Dapps=disabled -Dtests=disabled

ninja -C build

# Shrink the archive: drop debug info and the fat-LTO bitcode copies
# (leancrypto hardcodes -flto -ffat-lto-objects; the machine code remains).
# Note: linking your app with -flto gains nothing after this - link without it.
# Use the target binutils when cross-compiling (Yocto env sets $STRIP/$OBJCOPY).
${STRIP:-strip} --strip-debug build/libleancrypto.a
${OBJCOPY:-objcopy} --remove-section='.gnu.lto_*' --remove-section='.gnu.debuglto_*' build/libleancrypto.a

ls -lh build/libleancrypto.a

# Optional: ninja -C build install
# Link your application with: -Wl,--gc-sections (and strip the binary).
# If you can accept AVX2-accelerated code in the archive (runtime CPU
# detection, ~2x archive size, much faster): set -Ddisable-asm=false.
# Further shrink lever (not recommended): -Denable_selftests=disabled
