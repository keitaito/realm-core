# NOTE: THIS SCRIPT IS SUPPOSED TO RUN IN A POSIX SHELL

# Loads a .realm file in the user home directory if present
if [ -e $HOME/.realm ]; then
    . $HOME/.realm
fi

# Enable tracing if REALM_SCRIPT_DEBUG is set
if [ "$REALM_SCRIPT_DEBUG" ]; then
    set -x
fi

if ! [ "$REALM_ORIG_CWD" ]; then
    REALM_ORIG_CWD="$(pwd)" || exit 1
    export ORIG_CWD
fi

dir="$(dirname "$0")" || exit 1
cd "$dir" || exit 1
REALM_HOME="$(pwd)" || exit 1
export REALM_HOME

# Set mode to first argument and shift the argument array
MODE="$1"
[ $# -gt 0 ] && shift

# Extensions corresponding with additional GIT repositories
EXTENSIONS="java python ruby objc node php c gui replication"

# Auxiliary platforms
PLATFORMS="iphone"

OSX_SDKS="macosx"
OSX_DIR="macosx-lib"

IPHONE_EXTENSIONS="objc"
IPHONE_SDKS="iphoneos iphonesimulator"
IOS_DIR="ios-lib"
IOS_NO_BITCODE_DIR="ios-no-bitcode-lib"

WATCHOS_SDKS="watchos watchsimulator"
WATCHOS_DIR="watchos-lib"

TVOS_SDKS="appletvos appletvsimulator"
TVOS_DIR="tvos-lib"

: ${REALM_COCOA_PLATFORMS:="osx ios watchos tvos"}
: ${REALM_DOTNET_COCOA_PLATFORMS:="ios-no-bitcode"}

ANDROID_DIR="android-lib"
ANDROID_PLATFORMS="arm arm-v7a arm64 mips x86 x86_64"

NODE_DIR="node-lib"

CONFIG_VERSION=1
CURRENT_PLATFORM="win"
if [ "`uname`" = "Darwin" ]; then
  CURRENT_PLATFORM="osx"
fi
if [ "`uname`" = "Linux" ]; then
  CURRENT_PLATFORM="linux"
fi

usage()
{
    cat 1>&2 << EOF
Unspecified or bad mode '$MODE'.
Available modes are:
    config:
    clean:
    build:
    build-m32:                          build in 32-bit mode
    build-arm-benchmark:
    build-config-progs:
    build-osx:
    build-ios:
    build-ios-no-bitcode:
    build-watchos:
    build-tvos:
    build-android:
    build-cocoa:
    build-dotnet-cocoa:
    build-osx-framework:
    build-node:
    build-node-package:
    test:
    test-debug:
    check:
    check-debug:
    memcheck:
    memcheck-debug:
    check-testcase:
    check-testcase-debug:
    memcheck-testcase:
    memcheck-testcase-debug:
    asan:
    asan-debug:
    build-test-ios-app:                 build an iOS app for testing core on device
    test-ios-app:                       execute the core tests on device
    leak-test-ios-app:                  execute the core tests on device, monitor for leaks
    gdb:
    gdb-debug:
    gdb-testcase:
    gdb-testcase-debug:
    performance:
    benchmark:
    benchmark-*:
    lcov:
    gcovr:
    show-install:
    release-notes-prerelease:
    release-notes-postrelease:
    get-version:
    set-version:
    copy-tools:
    install:
    install-prod:
    install-devel:
    uninstall:
    uninstall-prod:
    uninstall-devel:
    test-installed:
    wipe-installed:
    src-dist:
    bin-dist:
    dist-config:
    dist-clean:
    dist-build:
    dist-build-iphone:
    dist-test:
    dist-test-debug:
    dist-install:
    dist-uninstall:
    dist-test-installed:
    dist-status:
    dist-pull:
    dist-checkout:
    dist-copy:
    jenkins-pull-request:               Run by Jenkins for each pull request whenever it changes
    jenkins-pipeline-unit-tests:        Run by Jenkins as part of the core pipeline whenever master changes
    jenkins-pipeline-coverage:          Run by Jenkins as part of the core pipeline whenever master changes
    jenkins-pipeline-address-sanitizer: Run by Jenkins as part of the core pipeline whenever master changes
    jenkins-valgrind:
EOF
}

map_ext_name_to_dir()
{
    local ext_name
    ext_name="$1"
    case $ext_name in
        *) echo "realm_$ext_name";;
    esac
    return 0
}

word_list_append()
{
    local list_name new_word list
    list_name="$1"
    new_word="$2"
    list="$(eval "printf \"%s\\n\" \"\${$list_name}\"")" || return 1
    if [ "$list" ]; then
        eval "$list_name=\"\$list \$new_word\""
    else
        eval "$list_name=\"\$new_word\""
    fi
    return 0
}

word_list_prepend()
{
    local list_name new_word list
    list_name="$1"
    new_word="$2"
    list="$(eval "printf \"%s\\n\" \"\${$list_name}\"")" || return 1
    if [ "$list" ]; then
        eval "$list_name=\"\$new_word \$list\""
    else
        eval "$list_name=\"\$new_word\""
    fi
    return 0
}

path_list_prepend()
{
    local list_name new_path list
    list_name="$1"
    new_path="$2"
    list="$(eval "printf \"%s\\n\" \"\${$list_name}\"")" || return 1
    if [ "$list" ]; then
        eval "$list_name=\"\$new_path:\$list\""
    else
        eval "$list_name=\"\$new_path\""
    fi
    return 0
}

word_list_reverse()
{
    local arg
    if [ "$#" -gt "0" ]; then
        arg="$1"
        shift
        word_list_reverse "$@"
        echo "$arg"
    fi
}

download_openssl()
{
    if [ -d openssl ]; then
        return 0
    fi

    local enabled
    enabled="$(get_config_param "ENABLE_ENCRYPTION")" || return 1
    if [ "$enabled" != "yes" ]; then
        return 0
    fi

    echo 'Downloading OpenSSL...'
    openssl_ver='1.0.2j'
    curl -L -s "http://www.openssl.org/source/openssl-${openssl_ver}.tar.gz" -o openssl.tar.gz || return 1
    tar -xzf openssl.tar.gz || return 1
    mv openssl-$openssl_ver openssl || return 1
    rm openssl.tar.gz || return 1
}

# Setup OS specific stuff
OS="$(uname)" || exit 1
ARCH="$(uname -m)" || exit 1
MAKE="make"
LD_LIBRARY_PATH_NAME="LD_LIBRARY_PATH"
if [ "$OS" = "Darwin" ]; then
    LD_LIBRARY_PATH_NAME="DYLD_LIBRARY_PATH"
fi
if ! printf "%s\n" "$MODE" | grep -q '^\(src-\|bin-\)\?dist'; then
    NUM_PROCESSORS=""
    if [ "$OS" = "Darwin" ]; then
        NUM_PROCESSORS="$(sysctl -n hw.ncpu)" || exit 1
    else
        if [ -r "/proc/cpuinfo" ]; then
            NUM_PROCESSORS="$(cat /proc/cpuinfo | grep -E 'processor[[:space:]]*:' | wc -l)" || exit 1
            LIMIT_LOAD_AVERAGE=YES
        fi
    fi
    if [ "$NUM_PROCESSORS" ]; then
        word_list_prepend MAKEFLAGS "-j$NUM_PROCESSORS ${LIMIT_LOAD_AVERAGE:+-l$MAX_LOAD_AVERAGE}" || exit 1
        export MAKEFLAGS

        if ! [ "$UNITTEST_THREADS" ]; then
            export UNITTEST_THREADS="$NUM_PROCESSORS"
        fi
    fi
fi
IS_REDHAT_DERIVATIVE=""
if [ -e /etc/redhat-release ] || grep -q "Amazon" /etc/system-release 2>/dev/null; then
    IS_REDHAT_DERIVATIVE="1"
fi
PLATFORM_HAS_LIBRARY_PATH_ISSUE=""
if [ "$IS_REDHAT_DERIVATIVE" ]; then
    PLATFORM_HAS_LIBRARY_PATH_ISSUE="1"
fi

build_apple()
{
    auto_configure || exit 1
    export REALM_HAVE_CONFIG="1"
    sdks_avail="$(get_config_param "$available_sdks_config_key")" || exit 1
    if [ "$sdks_avail" != "yes" ]; then
        echo "ERROR: Required $name SDKs are not available" 1>&2
        exit 1
    fi
    temp_dir="$(mktemp -d /tmp/realm.build-$os_name.XXXX)" || exit 1
    mkdir "$temp_dir/platforms" || exit 1
    xcode_home="$(get_config_param "XCODE_HOME")" || exit 1
    sdks="$(get_config_param "$sdks_config_key")" || exit 1
    for x in $sdks; do
        sdk="$(printf "%s\n" "$x" | cut -d: -f1)" || exit 1
        archs="$(printf "%s\n" "$x" | cut -d: -f2 | sed 's/,/ /g')" || exit 1
        cflags_arch="-stdlib=libc++ -m$os_name-version-min=$min_version"
        for y in $archs; do
            word_list_append "cflags_arch" "-arch $y" || exit 1
        done
        if [ "$sdk" = "${sdk%simulator}" ]; then
            if [ "$sdk" != "macosx" ]; then
                word_list_append "cflags_arch" "-mstrict-align" || exit 1
            fi
            if [ "$enable_bitcode" = "yes" ]; then
                word_list_append "cflags_arch" "-fembed-bitcode" || exit 1
            fi
        else
            if [ "$enable_bitcode" = "yes" ]; then
                word_list_append "cflags_arch" "-fembed-bitcode-marker" || exit 1
            fi
        fi
        tag="$sdk$platform_suffix"
        CC="xcrun -sdk $sdk clang" $MAKE -C "src/realm" "librealm-$tag.a" "librealm-$tag-dbg.a" BASE_DENOM="$tag" CFLAGS_ARCH="$cflags_arch" COMPILER_IS_GCC_LIKE=YES || exit 1
        mkdir "$temp_dir/platforms/$tag" || exit 1
        cp "src/realm/librealm-$tag.a"     "$temp_dir/platforms/$tag/librealm.a"     || exit 1
        cp "src/realm/librealm-$tag-dbg.a" "$temp_dir/platforms/$tag/librealm-dbg.a" || exit 1
    done
    all_caps_name=$(echo "$os_name" | tr "[:upper:]" "[:lower:]")
    $MAKE -C "src/realm" "realm-config-$os_name" "realm-config-$os_name-dbg" BASE_DENOM="$os_name" CFLAGS_ARCH="-fembed-bitcode -DREALM_CONFIG_$all_caps_name" AR="libtool" ARFLAGS="-o" || exit 1
    mkdir -p "$dir" || exit 1
    echo "Creating '$dir/librealm-$os_name$platform_suffix.a'"
    libtool "$temp_dir/platforms"/*/"librealm.a"     -static -o "$dir/librealm-$os_name$platform_suffix.a"     || exit 1
    echo "Creating '$dir/librealm-$os_name$platform_suffix-dbg.a'"
    libtool "$temp_dir/platforms"/*/"librealm-dbg.a" -static -o "$dir/librealm-$os_name$platform_suffix-dbg.a" || exit 1
    echo "Copying headers to '$dir/include'"
    mkdir -p "$dir/include" || exit 1
    cp "src/realm.hpp" "$dir/include/" || exit 1
    mkdir -p "$dir/include/realm" || exit 1
    inst_headers="$(cd "src/realm" && $MAKE --no-print-directory get-inst-headers)" || exit 1
    (cd "src/realm" && tar czf "$temp_dir/headers.tar.gz" $inst_headers) || exit 1
    (cd "$REALM_HOME/$dir/include/realm" && tar xzmf "$temp_dir/headers.tar.gz") || exit 1
    for x in "realm-config" "realm-config-dbg"; do
        echo "Creating '$dir/$x'"
        y="$(printf "%s\n" "$x" | sed "s/realm-config/realm-config-$os_name/")" || exit 1
        cp "src/realm/$y" "$REALM_HOME/$dir/$x" || exit 1
    done
    rm -rf "$temp_dir"
    echo "Done building"
    return 0
}

build_cocoa()
{
    local output_dir platforms
    file_basename="$1"
    output_dir="$2"
    platforms="$3"

    if [ "$OS" != "Darwin" ]; then
        echo "zip for iOS/OSX/watchOS/tvOS can only be generated under OS X."
        exit 0
    fi

    platforms=$(echo "$platforms" | sed -e 's/iphone/ios/g')

    for platform in $platforms; do
        sh build.sh build-$platform || exit 1
    done

    echo "Copying files"
    tmpdir=$(mktemp -d /tmp/$$.XXXXXX) || exit 1
    realm_version="$(sh build.sh get-version)" || exit 1
    dir_basename=core
    rm -f "$file_basename-$realm_version.zip" || exit 1
    mkdir -p "$tmpdir/$dir_basename/include" || exit 1

    platform_for_headers=$(echo $platforms | cut -d ' ' -f 1 | tr "-" "_" | tr "[:lower:]" "[:upper:]")
    eval headers_dir=\$${platform_for_headers}_DIR
    cp -r "$headers_dir/include/"* "$tmpdir/$dir_basename/include" || exit 1

    for platform in $platforms; do
        eval platform_dir=\$$(echo $platform | tr "-" "_" | tr "[:lower:]" "[:upper:]")_DIR
        cp "$platform_dir"/*.a "$tmpdir/$dir_basename" || exit 1
    done

    if [ -f "$tmpdir/$dir_basename"/librealm-macosx.a ]; then
        # If we built for OS X, add symlinks at the location of the old library names. This will give the bindings
        # a chance to update to the new names without breaking building with new versions of core.
        rm -f "$tmpdir/$dir_basename"/librealm{,-dbg}.a
        ln -sf librealm-macosx.a "$tmpdir/$dir_basename"/librealm.a
        ln -sf librealm-macosx-dbg.a "$tmpdir/$dir_basename"/librealm-dbg.a
    fi

    cp tools/LICENSE "$tmpdir/$dir_basename" || exit 1
    if ! [ "$REALM_DISABLE_MARKDOWN_CONVERT" ]; then
        command -v pandoc >/dev/null 2>&1 || { echo "Pandoc is required but it's not installed.  Aborting." >&2; exit 1; }
        pandoc -f markdown -t plain -o "$tmpdir/$dir_basename/CHANGELOG.txt" CHANGELOG.md || exit 1
    fi

    echo "Create zip file: '$file_basename-$realm_version.zip'"
    (cd $tmpdir && zip -r -q --symlinks "$file_basename-$realm_version.zip" "$dir_basename") || exit 1
    mv "$tmpdir/$file_basename-$realm_version.zip" . || exit 1

    echo "Unzipping in '$output_dir'"
    mkdir -p "$output_dir" || exit 1
    rm -rf "$output_dir/$dir_basename" || exit 1
    cur_dir="$(pwd)"
    (cd "$output_dir" && unzip -qq "$cur_dir/$file_basename-$realm_version.zip") || exit 1

    rm -rf "$tmpdir" || exit 1
    echo "Done"
}

find_apple_sdks()
{
    sdks=""
    if [ "$xcode_home" != "none" ]; then
        for x in $SDKS; do
            xcodebuild -version -sdk $x > /dev/null || exit 1
            if [ "$x" = "iphonesimulator" ]; then
                archs="i386,x86_64"
            elif [ "$x" = "iphoneos" ]; then
                archs="armv7,armv7s,arm64"
            elif [ "$x" = "watchsimulator" ]; then
                archs="i386"
            elif [ "$x" = "watchos" ]; then
                archs="armv7k"
            elif [ "$x" = "appletvsimulator" ]; then
                archs="x86_64"
            elif [ "$x" = "appletvos" ]; then
                archs="arm64"
            elif [ "$x" = "macosx" ]; then
                archs="x86_64"
            else
                continue
            fi
            word_list_append "sdks" "$x:$archs" || exit 1
        done
    fi
    echo "$sdks"
    return 0
}

# Find the path of most recent version of the installed Android NDKs
find_android_ndk()
{
    local ndks ndks_index current_ndk latest_ndk sorted highest result

    ndks_index=0

    # If homebrew is installed...
    if [ -d "/usr/local/Cellar/android-ndk" ]; then
        ndks[$ndks_index]="/usr/local/Cellar/android-ndk"
        ((ndks_index = ndks_index + 1))
    fi
    if [ -d "/usr/local/android-ndk" ]; then
        ndks[$ndks_index]="/usr/local/android-ndk"
        ((ndks_index = ndks_index + 1))
    fi
    if [ "$ndks_index" -eq 0 ]; then
        return 1
    fi

    highest=""
    result=""
    for ndk in "${ndks[@]}"; do
        for i in $(cd "$ndk" && echo *); do
            if [ -f "$ndk/$i/RELEASE.TXT" ]; then
                current_ndk=$(sed 's/^\(r\)\([0-9]\{1,\}\)\([a-z]\{0,1\}\)\(.*\)$/\1.\2.\3/' < "$ndk/$i/RELEASE.TXT") || return 1
                sorted="$(printf "%s\n%s\n" "$current_ndk" "$highest" | sort -t . -k2 -k3 -n -r)" || return 1
                highest="$(printf "%s\n" "$sorted" | head -n 1)" || return 1
                if [ $current_ndk = $highest ]; then
                    result=$ndk/$i
                fi
            fi
        done
    done

    if [ -z $result ]; then
        return 1
    fi

    printf "%s\n" "$result"
}

CONFIG_MK="src/config.mk"

require_config()
{
    cd "$REALM_HOME" || return 1
    if ! [ -e "$CONFIG_MK" ]; then
        cat 1>&2 <<EOF
ERROR: Found no configuration!
You need to run 'sh build.sh config [PREFIX]'.
EOF
        return 1
    fi
    echo "Using existing configuration in $CONFIG_MK:"
    cat "$CONFIG_MK" | sed 's/^/    /' || return 1

    config_version="$(get_config_param "CONFIG_VERSION")" || exit 1
    if [ "$config_version" != "$CONFIG_VERSION" ]; then
        cat 1>&2 <<EOF
ERROR: Found outdated configuration!
You need to rerun 'sh build.sh config [PREFIX]'
EOF
        return 1
    fi
}

auto_configure()
{
    cd "$REALM_HOME" || return 1
    if [ -e "$CONFIG_MK" ]; then
        require_config || return 1
    else
        echo "No configuration found. Running 'sh build.sh config' for you."
        sh build.sh config || return 1
    fi
}

get_config_param()
{
    local name home line value
    name="$1"
    home="$2"
    if ! [ "$home" ]; then
        home="$REALM_HOME"
    fi
    cd "$home" || return 1
    if ! [ -e "$CONFIG_MK" ]; then
        cat 1>&2 <<EOF
ERROR: Found no configuration!
You need to run 'sh build.sh config [PREFIX]'.
EOF
        return 1
    fi
    if ! line="$(grep "^$name *=" "$CONFIG_MK")"; then
        cat 1>&2 <<EOF
ERROR: Failed to read configuration parameter '$name'.
Maybe you need to rerun 'sh build.sh config [PREFIX]'.
EOF
        return 1
    fi
    value="$(printf "%s\n" "$line" | cut -d= -f2-)" || return 1
    value="$(printf "%s\n" "$value" | sed 's/^ *//')" || return 1
    printf "%s\n" "$value"
}

get_host_info()
{
    echo "\$ uname -a"
    uname -a
    if [ "$OS" = "Darwin" ]; then
        echo "\$ system_profiler SPSoftwareDataType"
        system_profiler SPSoftwareDataType | grep -v '^ *$'
    elif [ -e "/etc/issue" ]; then
        echo "\$ cat /etc/issue"
        cat "/etc/issue" | grep -v '^ *$'
    fi
}

get_compiler_info()
{
    local CC_CMD CXX_CMD LD_CMD
    CC_CMD="$($MAKE --no-print-directory get-cc)" || return 1
    CXX_CMD="$($MAKE --no-print-directory get-cxx)" || return 1
    LD_CMD="$($MAKE --no-print-directory get-ld)" || return 1
    echo "C compiler is '$CC_CMD' ($(which "$CC_CMD" 2>/dev/null))"
    echo "C++ compiler is '$CXX_CMD' ($(which "$CXX_CMD" 2>/dev/null))"
    echo "Linker is '$LD_CMD' ($(which "$LD_CMD" 2>/dev/null))"
    for x in $(printf "%s\n%s\n%s\n" "$CC_CMD" "$CXX_CMD" "$LD_CMD" | sort -u); do
        echo
        echo "\$ $x --version"
        $x --version 2>&1 | grep -v '^ *$'
    done
    if [ "$OS" = "Darwin" ]; then
        if xcode-select --print-path >/dev/null 2>&1; then
            echo
            echo "\$ xcodebuild -version"
            xcodebuild -version 2>&1 | grep -v '^ *$'
        fi
    fi
}

get_dist_log_path()
{
    local stem temp_dir path dir files max next
    stem="$1"
    temp_dir="$2"
    if [ "$REALM_DIST_LOG_FILE" ]; then
        path="$REALM_DIST_LOG_FILE"
    else
        if [ "$REALM_DIST_HOME" ]; then
            dir="$REALM_DIST_HOME/log"
        else
            dir="$temp_dir/log"
        fi
        mkdir -p "$dir" || return 1
        files="$(cd "$dir" && (ls *.log 2>/dev/null || true))" || return 1
        max="$(printf "%s\n" "$files" | grep '^[0-9][0-9]*_' | cut -d_ -f1 | sort -n | tail -n1)"
        max="$(printf "%s\n" "$max" | sed 's/^0*//')"
        next="$((max+1))" || return 1
        path="$dir/$(printf "%03d" "$next")_$stem.log"
    fi
    printf "%s\n" "$path"
}

build_node()
{
    auto_configure || exit 1
    export REALM_HAVE_CONFIG="1"
    $MAKE -C "src/realm" "librealm-node.a" "librealm-node-dbg.a" BASE_DENOM="node" EXTRA_CFLAGS="-fPIC -DPIC" || exit 1
}

case "$MODE" in

    "config")
        install_prefix="$1"
        if ! [ "$install_prefix" ]; then
            install_prefix="/usr/local"
        fi
        install_exec_prefix="$($MAKE --no-print-directory prefix="$install_prefix" get-exec-prefix)" || exit 1
        install_includedir="$($MAKE --no-print-directory prefix="$install_prefix" get-includedir)" || exit 1
        install_bindir="$($MAKE --no-print-directory prefix="$install_prefix" get-bindir)" || exit 1
        install_libdir="$($MAKE --no-print-directory prefix="$install_prefix" get-libdir)" || exit 1
        install_libexecdir="$($MAKE --no-print-directory prefix="$install_prefix" get-libexecdir)" || exit 1

        realm_version="unknown"
        if [ "$REALM_VERSION" ]; then
            realm_version="$REALM_VERSION"
        elif value="$(git describe 2>/dev/null)"; then
            realm_version="$(printf "%s\n" "$value" | sed 's/^v//')" || exit 1
        fi

        max_bpnode_size=1000
        max_bpnode_size_debug=1000
        if [ "$REALM_MAX_BPNODE_SIZE" ]; then
            max_bpnode_size="$REALM_MAX_BPNODE_SIZE"
        fi
        if [ "$REALM_MAX_BPNODE_SIZE_DEBUG" ]; then
            max_bpnode_size_debug="$REALM_MAX_BPNODE_SIZE_DEBUG"
        fi

        enable_alloc_set_zero="no"
        if [ "$REALM_ENABLE_ALLOC_SET_ZERO" ]; then
            enable_alloc_set_zero="yes"
        fi

        enable_encryption="no"
        if [ "$REALM_ENABLE_ENCRYPTION" ]; then
            enable_encryption="yes"
        fi

        enable_assertions="no"
        if [ "$REALM_ENABLE_ASSERTIONS" ]; then
            enable_assertions="yes"
        fi

        enable_memdebug="no"
        if [ "$REALM_ENABLE_MEMDEBUG" ]; then
            enable_memdebug="yes"
        fi
		
        # Find Xcode
        xcode_home="none"
        xcodeselect="xcode-select"
        if [ "$OS" = "Darwin" ]; then
            if path="$($xcodeselect --print-path 2>/dev/null)"; then
                xcode_home="$path"
            fi
            xcodebuild="$xcode_home/usr/bin/xcodebuild"
            version="$("$xcodebuild" -version)" || exit 1
            version="$(printf "%s" "$version" | grep -E '^Xcode +[0-9]+\.[0-9]' | head -n1)"
            version="$(printf "%s" "$version" | sed 's/^Xcode *\([0-9A-Z_.-]*\).*$/\1/')" || exit 1
            if ! printf "%s" "$version" | grep -q -E '^[0-9]+(\.[0-9]+)+$'; then
                echo "Failed to determine Xcode version using \`$xcodebuild -version\`" 1>&2
                exit 1
            fi
        fi

        # Find OS X SDKs
        osx_sdks_avail="no"
        osx_sdks="$(SDKS="$OSX_SDKS" find_apple_sdks)"
        if [ "$osx_sdks" != "" ]; then
            osx_sdks_avail="yes"
        fi

        # Find iPhone SDKs
        iphone_sdks_avail="no"
        iphone_sdks="$(SDKS="$IPHONE_SDKS" find_apple_sdks)"
        if [ "$iphone_sdks" != "" ]; then
            iphone_sdks_avail="yes"
        fi

        # Find watchOS SDKs
        watchos_sdks_avail="no"
        watchos_sdks="$(SDKS="$WATCHOS_SDKS" find_apple_sdks)"
        if [ "$watchos_sdks" != "" ]; then
            watchos_sdks_avail="yes"
        fi

        # Find tvOS SDKs
        tvos_sdks_avail="no"
        tvos_sdks="$(SDKS="$TVOS_SDKS" find_apple_sdks)"
        if [ "$tvos_sdks" != "" ]; then
            tvos_sdks_avail="yes"
        fi

        # Find Android NDK
        if [ "$ANDROID_NDK_HOME" ]; then
            android_ndk_home="$ANDROID_NDK_HOME"
        else
            android_ndk_home="$(find_android_ndk)" || android_ndk_home="none"
        fi

        cat >"$CONFIG_MK" <<EOF
CONFIG_VERSION        = ${CONFIG_VERSION}
REALM_VERSION         = $realm_version
INSTALL_PREFIX        = $install_prefix
INSTALL_EXEC_PREFIX   = $install_exec_prefix
INSTALL_INCLUDEDIR    = $install_includedir
INSTALL_BINDIR        = $install_bindir
INSTALL_LIBDIR        = $install_libdir
INSTALL_LIBEXECDIR    = $install_libexecdir
MAX_BPNODE_SIZE       = $max_bpnode_size
MAX_BPNODE_SIZE_DEBUG = $max_bpnode_size_debug
ENABLE_ASSERTIONS     = $enable_assertions
ENABLE_MEMDEBUG       = $enable_memdebug
ENABLE_ALLOC_SET_ZERO = $enable_alloc_set_zero
ENABLE_ENCRYPTION     = $enable_encryption
XCODE_HOME            = $xcode_home
OSX_SDKS              = ${osx_sdks:-none}
OSX_SDKS_AVAIL        = $osx_sdks_avail
IPHONE_SDKS           = ${iphone_sdks:-none}
IPHONE_SDKS_AVAIL     = $iphone_sdks_avail
WATCHOS_SDKS          = ${watchos_sdks:-none}
WATCHOS_SDKS_AVAIL    = $watchos_sdks_avail
TVOS_SDKS             = ${tvos_sdks:-none}
TVOS_SDKS_AVAIL       = $tvos_sdks_avail
ANDROID_NDK_HOME      = $android_ndk_home
EOF
        if ! [ "$INTERACTIVE" ]; then
            echo "New configuration in $CONFIG_MK:"
            cat "$CONFIG_MK" | sed 's/^/    /' || exit 1
            echo "Done configuring"
        fi
        exit 0
        ;;

    "clean")
        auto_configure || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE clean || exit 1
        if [ "$OS" = "Darwin" ]; then
            for x in $OSX_SDKS $IPHONE_SDKS $WATCHOS_SDKS $TVOS_SDKS; do
                $MAKE -C "src/realm" clean BASE_DENOM="$x" || exit 1
            done
            $MAKE -C "src/realm" clean BASE_DENOM="ios" || exit 1
            $MAKE -C "src/realm" clean BASE_DENOM="watch" || exit 1
            $MAKE -C "src/realm" clean BASE_DENOM="tv" || exit 1
            for dir in "$OSX_DIR" "$IOS_DIR" "$IOS_NO_BITCODE_DIR" "$WATCHOS_DIR" "$TVOS_DIR"; do
                if [ -e "$dir" ]; then
                    echo "Removing '$dir'"
                    rm -rf "$dir/include" || exit 1
                    rm -f "$dir/"librealm-*.a || exit 1
                    rm -f "$dir"/realm-config* || exit 1
                    rmdir "$dir" || exit 1
                fi
            done
        fi
        for x in $ANDROID_PLATFORMS; do
            denom="android-$x"
            $MAKE -C "src/realm" clean BASE_DENOM="$denom" || exit 1
        done
        if [ -e "$ANDROID_DIR" ];then
            echo "Removing '$ANDROID_DIR'"
            rm -rf "$ANDROID_DIR"
        fi
        echo "Done cleaning"
        exit 0
        ;;

    "build")
        auto_configure || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE || exit 1
        echo "Done building"
        exit 0
        ;;

    "build-m32")
        auto_configure || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE EXTRA_CFLAGS="-m32" BASE_DENOM="m32" debug || exit 1
        echo "Done building"
        exit 0
        ;;

    "build-config-progs")
        auto_configure || exit 1
        export REALM_HAVE_CONFIG="1"
        # FIXME: Apparently, there are fluke cases where timestamps
        # are such that <src/realm/util/config.h> is not recreated
        # automatically by src/realm/Makfile. Using --always-make is
        # a work-around.
        $MAKE --always-make -C "src/realm" "realm-config" "realm-config-dbg" || exit 1
        echo "Done building config programs"
        exit 0
        ;;

    "build-osx")
        export name='OS X'
        export available_sdks_config_key='OSX_SDKS_AVAIL'
        export min_version='10.8'
        export os_name='macosx'
        export sdks_config_key='OSX_SDKS'
        export dir="$OSX_DIR"
        export platform_suffix=''
        export enable_bitcode='no'
        build_apple
        ;;

    "build-ios" | "build-iphone")
        export name='iPhone'
        export available_sdks_config_key='IPHONE_SDKS_AVAIL'
        export min_version='7.0'
        export os_name='ios'
        export sdks_config_key='IPHONE_SDKS'
        export dir="$IOS_DIR"
        export platform_suffix=''
        export enable_bitcode='yes'
        build_apple
        ;;

    "build-ios-no-bitcode" | "build-iphone-no-bitcode")
        export name='iPhone'
        export available_sdks_config_key='IPHONE_SDKS_AVAIL'
        export min_version='7.0'
        export os_name='ios'
        export sdks_config_key='IPHONE_SDKS'
        export dir="$IOS_NO_BITCODE_DIR"
        export platform_suffix='-no-bitcode'
        export enable_bitcode='no'
        build_apple
        ;;

    "build-watchos")
        export name='watchOS'
        export available_sdks_config_key='WATCHOS_SDKS_AVAIL'
        export min_version='2.0'
        export os_name='watchos'
        export sdks_config_key='WATCHOS_SDKS'
        export dir="$WATCHOS_DIR"
        export platform_suffix=''
        export enable_bitcode='yes'
        build_apple
        ;;

    "build-tvos")
        export name='tvOS'
        export available_sdks_config_key='TVOS_SDKS_AVAIL'
        export min_version='9.0'
        export os_name='tvos'
        export sdks_config_key='TVOS_SDKS'
        export dir="$TVOS_DIR"
        export platform_suffix=''
        export enable_bitcode='yes'
        build_apple
        ;;

    "build-android")
        auto_configure || exit 1
        download_openssl || exit 1

        export REALM_HAVE_CONFIG="1"
        android_ndk_home="$(get_config_param "ANDROID_NDK_HOME")" || exit 1
        if [ "$android_ndk_home" = "none" ]; then
            cat 1>&2 <<EOF
ERROR: Android NDK was not found during configuration.
Please do one of the following:
 * Install an NDK in /usr/local/android-ndk
 * Provide the path to the NDK in the environment variable ANDROID_NDK_HOME
 * If on OSX and using Homebrew install the package android-sdk
EOF
            exit 1
        fi

        enable_encryption="$(get_config_param "ENABLE_ENCRYPTION")" || return 1
        echo "Encryption enabled: ${enable_encryption}"

        export REALM_ANDROID="1"
        mkdir -p "$ANDROID_DIR" || exit 1
        for target in $ANDROID_PLATFORMS; do
            temp_dir="$(mktemp -d /tmp/realm.build-android.XXXX)" || exit 1
            if [ "$target" = "arm" ]; then
                platform="8"
            elif [ "$target" = "arm64" -o "$target" = "x86_64" ]; then
                platform="21"
            else
                platform="9"
            fi

            if [ "$target" = "arm" -o "$target" = "arm-v7a" ]; then
                arch="arm"
                android_prefix="arm"
                android_toolchain="arm-linux-androideabi-4.9"
            elif [ "$target" = "arm64" ]; then
                arch="arm64"
                android_prefix="aarch64"
                android_toolchain="aarch64-linux-android-4.9"
            elif [ "$target" = "mips" ]; then
                arch="mips"
                android_prefix="mipsel"
                android_toolchain="mipsel-linux-android-4.9"
            elif [ "$target" = "x86" ]; then
                arch="x86"
                android_prefix="i686"
                android_toolchain="x86-4.9"
            elif [ "$target" = "x86_64" ]; then
                arch="x86_64"
                android_prefix="x86_64"
                android_toolchain="x86_64-4.9"
            fi
            # Note that `make-standalone-toolchain.sh` is written for
            # `bash` and must therefore be executed by `bash`.
            make_toolchain="$android_ndk_home/build/tools/make-standalone-toolchain.sh"
            bash "$make_toolchain" --platform="android-$platform" --toolchain="$android_toolchain" --install-dir="$temp_dir" --arch="$arch" || exit 1

            path="$temp_dir/bin:$PATH"
            cc="$(cd "$temp_dir/bin" && echo $android_prefix-linux-*-gcc)" || exit 1
            cflags_arch=""
            if [ "$target" = "arm" ]; then
                word_list_append "cflags_arch" "-mthumb" || exit 1
            elif [ "$target" = "arm-v7a" ]; then
                word_list_append "cflags_arch" "-mthumb -march=armv7-a -mfloat-abi=softfp -mfpu=vfpv3-d16" || exit 1
            fi
            denom="android-$target"

            # Build OpenSSL if needed
            repodir=$(pwd)
            libcrypto_name="libcrypto-$denom.a"
            if ! [ -f "$ANDROID_DIR/$libcrypto_name" ] && [ "$enable_encryption" = "yes" ]; then
                (
                    cd openssl
                    export MACHINE=$target
                    export RELEASE=unknown
                    export SYSTEM=android
                    export ARCH=arm
                    export HOSTCC=gcc
                    export PATH="$path"
                    export CC="$cc"
                    ./config no-idea no-camellia no-seed no-bf no-cast no-des \
                             no-rc2 no-rc4 no-rc5 no-md2 no-md4 no-ripemd \
                             no-mdc2 no-rsa no-dsa no-dh no-ec no-ecdsa no-ecdh \
                             no-sock no-ssl2 no-ssl3 no-err no-krb5 no-engine \
                             no-srtp no-speed -DOPENSSL_NO_SHA512 \
                             -DOPENSSL_NO_SHA0 -w -fPIC || exit 1
                    $MAKE clean
                ) || exit 1

                # makedepend interprets -mandroid as -m
                (cd openssl && mv Makefile Makefile.dep && sed -e 's/\-mandroid//g' Makefile.dep > Makefile) || exit 1
                DEPFLAGS="$(grep DEPFLAG= Makefile | head -1 | cut -f2 -d=)"
                $MAKE -C "openssl" DEPFLAG="$DEPFLAGS -I$temp_dir/sysroot/usr/include -I$temp_dir/sysroot/usr/include/linux -I$temp_dir/include/c++/4.9/tr1 -I$temp_dir/include/c++/4.9" depend || exit 1
                # -O3 seems to be buggy on Android
                (cd openssl && sed -e 's/O3/Os/g' Makefile.dep > Makefile && rm -f Makefile.dep) || exit 1
                PATH="$path" CC="$cc" CFLAGS="$cflags_arch" PERL="perl" $MAKE -C "openssl" build_crypto || exit 1
                cp "openssl/libcrypto.a" "$ANDROID_DIR/$libcrypto_name" || exit 1
            fi

            # Build realm
            PATH="$path" CC="$cc" $MAKE -C "src/realm" CC_IS="gcc" BASE_DENOM="$denom" CFLAGS_ARCH="$cflags_arch" "librealm-$denom.a" "librealm-$denom-dbg.a" || exit 1

            if [ "$enable_encryption" = "yes" ]; then
                # Merge OpenSSL and Realm into one static library
                for lib_name in "librealm-$denom.a" "librealm-$denom-dbg.a"; do
                    (
                        TMP_FOLDER=$(mktemp -d /tmp/$$.XXXXXX)
                        cd $TMP_FOLDER
                        AR="$(echo "$temp_dir/bin/$android_prefix-linux-*-gcc-ar")" || exit 1
                        RANLIB="$(echo "$temp_dir/bin/$android_prefix-linux-*-gcc-ranlib")" || exit 1
                        $AR x "$repodir/$ANDROID_DIR/$libcrypto_name" || exit 1
                        $AR x "$repodir/src/realm/$lib_name" || exit 1
                        $AR r "$repodir/$ANDROID_DIR/$lib_name" *.o || exit 1
                        $RANLIB "$repodir/$ANDROID_DIR/$lib_name"
                        cd -
                        rm -rf $TMP_FOLDER
                    ) || exit 1
                done

                echo 'This product includes software developed by the OpenSSL Project for use in the OpenSSL toolkit. (http://www.openssl.org/).' > $ANDROID_DIR/OpenSSL.txt
                echo '' >> $ANDROID_DIR/OpenSSL.txt
                echo 'The following license applies only to the portions of this product developed by the OpenSSL Project.' >> $ANDROID_DIR/OpenSSL.txt
                echo '' >> $ANDROID_DIR/OpenSSL.txt

                cat openssl/LICENSE >> $ANDROID_DIR/OpenSSL.txt
            else
                cp "src/realm/librealm-$denom.a" "$ANDROID_DIR" || exit 1
                cp "src/realm/librealm-$denom-dbg.a" "$ANDROID_DIR" || exit 1
            fi

            rm -rf "$temp_dir" || exit 1
        done

        echo "Copying headers to '$ANDROID_DIR/include'"
        mkdir -p "$ANDROID_DIR/include" || exit 1
        cp "src/realm.hpp" "$ANDROID_DIR/include/" || exit 1
        mkdir -p "$ANDROID_DIR/include/realm" || exit 1
        inst_headers="$(cd "src/realm" && $MAKE --no-print-directory get-inst-headers)" || exit 1
        temp_dir="$(mktemp -d /tmp/realm.build-android.XXXX)" || exit 1
        (cd "src/realm" && tar czf "$temp_dir/headers.tar.gz" $inst_headers) || exit 1
        (cd "$REALM_HOME/$ANDROID_DIR/include/realm" && tar xzmf "$temp_dir/headers.tar.gz") || exit 1
        rm -rf "$temp_dir" || exit 1

        realm_version="$(sh build.sh get-version)" || exit
        dir_name="core-$realm_version"
        file_name="realm-core-android-$realm_version.tar.gz"
        tar_files='librealm*'
        if [ "$enable_encryption" = "yes" ]; then
            tar_files='librealm* *.txt'
        fi

        echo "Create tar.gz file $file_name"
        rm -f "$REALM_HOME/$file_name" || exit 1
        (cd "$REALM_HOME/$ANDROID_DIR" && tar czf "$REALM_HOME/$file_name" include $tar_files) || exit 1

        echo "Copying to ../realm-java/"
        mkdir -p ../realm-java/ || exit 1 # to help Mr. Jenkins
        cp "$REALM_HOME/$file_name" "../realm-java/core-android-$realm_version.tar.gz"
        ;;

    "build-cocoa")
        # the user can specify where to find realm-cocoa repository
        realm_cocoa_dir="$1"
        if [ -z "$realm_cocoa_dir" ]; then
            realm_cocoa_dir="../realm-cocoa"
        fi
        file_basename="core" # FIXME: we should change this to realm-core-cocoa everywhere

        build_cocoa "$file_basename" "$realm_cocoa_dir" "$REALM_COCOA_PLATFORMS"
        exit 0
        ;;

    "build-dotnet-cocoa")
        # the user can specify where to place the extracted output
        output_dir="$1"
        if [ -z "$output_dir" ]; then
            output_dir="../realm-dotnet/wrappers"
        fi
        file_basename="realm-core-dotnet-cocoa"

        build_cocoa "$file_basename" "$output_dir" "$REALM_DOTNET_COCOA_PLATFORMS"
        exit 0
        ;;

    "build-osx-framework")
        if [ "$OS" != "Darwin" ]; then
            echo "Framework for OS X can only be generated under Mac OS X."
            exit 0
        fi

        realm_version="$(sh build.sh get-version)"
        BASENAME="RealmCore"
        FRAMEWORK="$BASENAME.framework"
        rm -rf "$FRAMEWORK" || exit 1
        rm -f realm-core-osx-*.zip || exit 1

        mkdir -p "$FRAMEWORK/Headers/realm" || exit 1
        if [ ! -f "src/realm/librealm.a" ]; then
            echo "\"src/realm/librealm.a\" missing."
            echo "Did you forget to build?"
            exit 1
        fi

        cp "src/realm/librealm.a" "$FRAMEWORK/$BASENAME" || exit 1
        cp "src/realm.hpp" "$FRAMEWORK/Headers/realm.hpp" || exit 1
        for header in $(cd "src/realm" && $MAKE --no-print-directory get-inst-headers); do
            mkdir -p "$(dirname "$FRAMEWORK/Headers/realm/$header")" || exit 1
            cp "src/realm/$header" "$FRAMEWORK/Headers/realm/$header" || exit 1
        done
        find "$FRAMEWORK/Headers" -iregex "^.*\.[ch]\(pp\)\{0,1\}$" \
            -exec sed -i '' -e "s/<realm\(.*\)>/<$BASENAME\/realm\1>/g" {} \; || exit 1

        zip -r -q realm-core-osx-$realm_version.zip $FRAMEWORK || exit 1
        echo "Core framework for OS X can be found under $FRAMEWORK and realm-core-osx-$realm_version.zip."
        exit 0
        ;;

    "build-node")
        build_node
        exit 0
        ;;

    "build-node-package")
        build_node

        dir_basename=core
        node_directory="$NODE_DIR/$dir_basename"

        mkdir -p "$node_directory" || exit 1
        cp "src/realm/librealm-node.a" "$node_directory" || exit 1
        cp "src/realm/librealm-node-dbg.a" "$node_directory" || exit 1

        echo "Copying headers to '$node_directory/include'"
        mkdir -p "$node_directory/include" || exit 1
        cp "src/realm.hpp" "$node_directory/include/" || exit 1
        mkdir -p "$node_directory/include/realm" || exit 1
        inst_headers="$(cd "src/realm" && $MAKE --no-print-directory get-inst-headers)" || exit 1
        temp_dir="$(mktemp -d /tmp/realm.build-node.XXXX)" || exit 1
        (cd "src/realm" && tar czf "$temp_dir/headers.tar.gz" $inst_headers) || exit 1
        (cd "$REALM_HOME/$node_directory/include/realm" && tar xzmf "$temp_dir/headers.tar.gz") || exit 1
        rm -rf "$temp_dir" || exit 1

        cp tools/LICENSE "$node_directory" || exit 1
        if ! [ "$REALM_DISABLE_MARKDOWN_CONVERT" ]; then
            command -v pandoc >/dev/null 2>&1 || { echo "Pandoc is required but it's not installed.  Aborting." >&2; exit 1; }
            pandoc -f markdown -t plain -o "$node_directory/CHANGELOG.txt" CHANGELOG.md || exit 1
        fi

        realm_version="$(sh build.sh get-version)" || exit
        dir_name="core-$realm_version"
        file_name="realm-core-node-$CURRENT_PLATFORM-$realm_version.tar.gz"
        tar_files='librealm*'

        echo "Create tar.gz file $file_name"
        rm -f "$REALM_HOME/$file_name" || exit 1
        (cd "$REALM_HOME/$NODE_DIR" && tar czf "$REALM_HOME/$file_name" $dir_basename) || exit 1

        exit 0
        ;;

    "test"|"test-debug"|\
    "check"|"check-debug"|\
    "memcheck"|"memcheck-debug"|\
    "check-testcase"|"check-testcase-debug"|\
    "memcheck-testcase"|"memcheck-testcase-debug")
        auto_configure || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE "$MODE" || exit 1
        echo "Test passed"
        exit 0
        ;;

    "asan"|"asan-debug")
        # Run test suite with GCC's address sanitizer enabled.
        # To get symbolized stack traces (file names and line numbers) with GCC, you at least version 4.9.
        check_mode="$(printf "%s\n" "$MODE" | sed 's/asan/check/')" || exit 1
        auto_configure || exit 1
        touch "$CONFIG_MK" || exit 1 # Force complete rebuild
        export ASAN_OPTIONS="detect_odr_violation=2"
        export REALM_HAVE_CONFIG="1"
        error=""
        if ! UNITTEST_THREADS="1" UNITTEST_PROGRESS="1" $MAKE EXTRA_CFLAGS="-fsanitize=address" EXTRA_LDFLAGS="-fsanitize=address" "$check_mode"; then
            error="1"
        fi
        touch "$CONFIG_MK" || exit 1 # Force complete rebuild
        if [ "$error" ]; then
            exit 1
        fi
        echo "Test passed"
        exit 0
        ;;

    "tsan"|"tsan-debug")
        # Run test suite with GCC's thread sanitizer enabled.
        # To get symbolized stack traces (file names and line numbers) with GCC, you at least version 4.9.
        check_mode="$(printf "%s\n" "$MODE" | sed 's/tsan/check/')" || exit 1
        auto_configure || exit 1
        touch "$CONFIG_MK" || exit 1 # Force complete rebuild
        export REALM_HAVE_CONFIG="1"
        error=""
        if ! UNITTEST_THREADS="1" UNITTEST_PROGRESS="1" $MAKE EXTRA_CFLAGS="-fsanitize=thread" EXTRA_LDFLAGS="-fsanitize=thread" "$check_mode"; then
            error="1"
        fi
        touch "$CONFIG_MK" || exit 1 # Force complete rebuild
        if [ "$error" ]; then
            exit 1
        fi
        echo "Test passed"
        exit 0
        ;;

    "build-test-ios-app")
        # For more documentation, see test/ios/README.md.

        ARCHS="\$(ARCHS_STANDARD_INCLUDING_64_BIT)"
        while getopts da: OPT; do
            case $OPT in
                d)  DEBUG=1
                    ;;
                a)  ARCHS=$OPTARG
                    ;;
                *)  usage
                    exit 1
                    ;;
            esac
        done

        sh build.sh build-ios

        TMPL_DIR="test/ios/template"
        TEST_DIR="test/ios/app"
        rm -rf "$TEST_DIR/"* || exit 1
        mkdir -p "$TEST_DIR" || exit 1

        APP="iOSTestCoreApp"
        TEST_APP="${APP}Tests"

        APP_DIR="$TEST_DIR/$APP"
        TEST_APP_DIR="$TEST_DIR/$TEST_APP"

        # Copy the test files into the app tests subdirectory
        PASSIVE_SUBDIRS="$($MAKE -C ./test --no-print-directory get-passive-subdirs)" || exit 1
        PASSIVE_SUBDIRS="$PASSIVE_SUBDIRS android ios" # dirty skip
        PASSIVE_SUBDIRS="$(echo "$PASSIVE_SUBDIRS" | sed -E 's/ +/|/g')" || exit 1
        # Naive copy, i.e. copy everything.
        ## Avoid recursion (extra precaution) and passive subdirs.
        ## Avoid non-source-code files.
        ## Retain directory structure.
        (cd ./test && find -E . \
            ! -iregex "^\./(ios|$PASSIVE_SUBDIRS)/.*$" \
            -a -iregex "^.*\.[ch](pp)?$" \
            -exec rsync -qR {} "../$TEST_APP_DIR" \;) || exit 1
        rm "$TEST_APP_DIR/main.cpp"

        # Gather resources
        RESOURCES="$($MAKE -C ./test --no-print-directory get-test-resources)" || exit 1
        (cd ./test && rsync $RESOURCES "../$APP_DIR") || exit 1
        RESOURCES="$(echo "$RESOURCES" | sed -E "s/(^| )/\1$APP\//g")" || exit 1

        # Set up frameworks, or rather, static libraries.
        rm -rf "$TEST_DIR/$IPHONE_DIR" || exit 1
        cp -r "../realm/$IPHONE_DIR" "$TEST_DIR/$IPHONE_DIR" || exit 1
        if [ -n "$DEBUG" ]; then
            FRAMEWORK="$IPHONE_DIR/librealm-ios-dbg.a"
        else
            FRAMEWORK="$IPHONE_DIR/librealm-ios.a"
        fi
        FRAMEWORKS="'$FRAMEWORK'"
        HEADER_SEARCH_PATHS="'$IPHONE_DIR/include/**'"

        # Other flags
        if [ -n "$DEBUG" ]; then
            OTHER_CPLUSPLUSFLAGS="'-DREALM_DEBUG'"
        fi

        # Initialize app directory
        cp -r "test/ios/template/App/"* "$APP_DIR" || exit 1
        mv "$APP_DIR/App-Info.plist" "$APP_DIR/$APP-Info.plist" || exit 1
        mv "$APP_DIR/App-Prefix.pch" "$APP_DIR/$APP-Prefix.pch" || exit 1

        # Gather all the test sources in a Python-friendly format.
        ## The indentation is to make it look pretty in the Gyp file.
        APP_SOURCES=$(cd $TEST_DIR && find "$TEST_APP" -type f | \
            sed -E "s/^(.*)$/                '\1',/") || exit 1
        TEST_APP_SOURCES="$APP_SOURCES"

        # Prepare for GYP
        ARCHS="$(echo "'$ARCHS'," | sed -E "s/ /', '/g")" || exit 1
        RESOURCES="$(echo "'$RESOURCES'," | sed -E "s/ /', '/g")" || exit 1

        # Generate a Gyp file.
        . "$TMPL_DIR/App.gyp.sh"

        # Run gyp, generating an .xcodeproj folder with a project.pbxproj file.
        gyp --depth="$TEST_DIR" "$TEST_DIR/$APP.gyp" || exit 1

        ## Collect the main app id from the project.pbxproj file.
        APP_ID=$(cat "$TEST_DIR/$APP.xcodeproj/project.pbxproj" | tr -d '\n' | \
            egrep -o "remoteGlobalIDString.*?remoteInfo = $APP;" | \
            head -n 1 | \
            sed 's/remoteGlobalIDString = \([A-F0-9]*\);.*/\1/') || exit 1

        ## Collect the test app id from the project.pbxproj file.
        TEST_APP_ID=$(cat "$TEST_DIR/$APP.xcodeproj/project.pbxproj" | tr -d '\n' | \
            egrep -o "remoteGlobalIDString.*?remoteInfo = $TEST_APP;" | \
            head -n 1 | \
            sed 's/remoteGlobalIDString = \([A-F0-9]*\);.*/\1/') || exit 1

        ## Generate a scheme with a test action.
        USER=$(whoami)
        mkdir -p "$TEST_DIR/$APP.xcodeproj/xcuserdata"
        mkdir -p "$TEST_DIR/$APP.xcodeproj/xcuserdata/$USER.xcuserdatad"
        mkdir -p "$TEST_DIR/$APP.xcodeproj/xcuserdata/$USER.xcuserdatad/xcschemes"

        . "$TMPL_DIR/App.scheme.sh"

        echo "The app is now available under $TEST_DIR."
        echo "Use sh build.sh (leak-)test-ios-app to run the app on device."

        exit 0
        ;;

    "test-ios-app")
        # Prerequisites: build-test-ios-app
        # For more documentation, see test/ios/README.md
        (cd "test/ios/app" &&
            if [ $# -eq 0 ]; then
                xcodebuild test -scheme iOSTestCoreApp \
                    -destination "platform=iOS,name=realm's iPad"
            else
                xcodebuild test -scheme iOSTestCoreApp "$@"
            fi)
        exit 0
        ;;

    "leak-test-ios-app")
        # Prerequisites: build-test-ios-app
        # For more documentation, see test/ios/README.md
        DEV="realm's iPad"
        if [ $# -ne 0 ]; then
            DEV="$@"
        fi
        (cd "test/ios/app" && instruments -t ../template/Leaks.tracetemplate \
            -w "$DEV" iOSTestCoreApp)
        exit 0
        ;;

    "gdb"|"gdb-debug"|\
    "gdb-testcase"|"gdb-testcase-debug"|\
    "lldb"|"lldb-debug"|\
    "lldb-testcase"|"lldb-testcase-debug"|\
    "performance"|"benchmark"|"benchmark-"*|\
    "check-cover"|"check-cover-norun"|"lcov"|"gcovr")
        auto_configure || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE "$MODE" || exit 1
        exit 0
        ;;

    "show-install")
        temp_dir="$(mktemp -d /tmp/realm.show-install.XXXX)" || exit 1
        mkdir "$temp_dir/fake-root" || exit 1
        DESTDIR="$temp_dir/fake-root" sh build.sh install >/dev/null || exit 1
        (cd "$temp_dir/fake-root" && find * \! -type d >"$temp_dir/list") || exit 1
        sed 's|^|/|' <"$temp_dir/list" || exit 1
        rm -fr "$temp_dir/fake-root" || exit 1
        rm "$temp_dir/list" || exit 1
        rmdir "$temp_dir" || exit 1
        exit 0
        ;;

    "release-notes-prerelease")
        RELEASE_HEADER="# $(sh build.sh get-version) Release notes" || exit 1
        sed -i.bak "1s/.*/$RELEASE_HEADER/" CHANGELOG.md || exit 1
        rm CHANGELOG.md.bak
        exit 0
        ;;

    "release-notes-postrelease")
        cat doc/CHANGELOG_template.md CHANGELOG.md > CHANGELOG.md.new || exit 1
        mv CHANGELOG.md.new CHANGELOG.md || exit 1
        exit 0
        ;;

    "get-version")
        version_file="src/realm/version.hpp"
        realm_ver_major="$(grep ^"#define REALM_VER_MAJOR" $version_file | awk '{print $3}')" || exit 1
        realm_ver_minor="$(grep ^"#define REALM_VER_MINOR" $version_file | awk '{print $3}')" || exit 1
        realm_ver_patch="$(grep ^"#define REALM_VER_PATCH" $version_file | awk '{print $3}')" || exit 1
        realm_ver_extra="$(grep ^"#define REALM_VER_EXTRA" $version_file | awk '{print $3}' | tr -d '\"')" || exit 1
        if [ -z "$realm_ver_extra" ]; then
            echo "$realm_ver_major.$realm_ver_minor.$realm_ver_patch"
        else
            echo "$realm_ver_major.$realm_ver_minor.$realm_ver_patch-$realm_ver_extra"
        fi
        exit 0
        ;;

    "set-version")
        realm_version="$1"
        version_file="src/realm/version.hpp"
        realm_ver_major="$(echo "$realm_version" | cut -f1 -d.)" || exit 1
        realm_ver_minor="$(echo "$realm_version" | cut -f2 -d.)" || exit 1
        realm_ver_patch="$(echo "$realm_version" | cut -f3 -d. | cut -f1 -d-)" || exit 1
        realm_ver_extra="$(echo "$realm_version" | cut -f3 -d. | cut -f2 -s -d-)" || exit 1

        # update version.hpp
        printf ",s/#define REALM_VER_MAJOR .*/#define REALM_VER_MAJOR $realm_ver_major/\nw\nq" | ed -s "$version_file" || exit 1
        printf ",s/#define REALM_VER_MINOR .*/#define REALM_VER_MINOR $realm_ver_minor/\nw\nq" | ed -s "$version_file" || exit 1
        printf ",s/#define REALM_VER_PATCH .*/#define REALM_VER_PATCH $realm_ver_patch/\nw\nq" | ed -s "$version_file" || exit 1
        printf ",s/#define REALM_VER_EXTRA .*/#define REALM_VER_EXTRA \"$realm_ver_extra\"/\nw\nq" | ed -s "$version_file" || exit 1

        # update dependencies.list
        sed -i.bck "s/^VERSION.*/VERSION=$realm_version/" dependencies.list && rm -f dependencies.list.bck

        sh build.sh release-notes-prerelease || exit 1
        exit 0
        ;;

    "copy-tools")
        repo="$1"
        if [ -z "$repo" ]; then
            echo "No path to repository set: sh build.sh copy-tools <path-to-repo>"
            exit 1
        fi
        if ! [ -e "$repo" ]; then
            echo "Repository $repo does not exist"
            exit 1
        fi
        mkdir -p $repo/tools || exit 1

        tools="add-deb-changelog.sh"
        for t in $tools; do
            cp tools/$t $repo/tools || exit 1
            sed -i -e "1i # Do not edit here - go to core repository" $repo/tools/$t || exit 1
        done
        exit 0
        ;;

    "install")
        require_config || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE install-only DESTDIR="$DESTDIR" || exit 1
        if [ "$USER" = "root" ] && which ldconfig >/dev/null 2>&1; then
            ldconfig || exit 1
        fi
        echo "Done installing"
        exit 0
        ;;

    "install-prod")
        require_config || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE install-only DESTDIR="$DESTDIR" INSTALL_FILTER="shared-libs,progs" || exit 1
        if [ "$USER" = "root" ] && which ldconfig >/dev/null 2>&1; then
            ldconfig || exit 1
        fi
        echo "Done installing"
        exit 0
        ;;

    "install-devel")
        require_config || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE install-only DESTDIR="$DESTDIR" INSTALL_FILTER="static-libs,dev-progs,headers" || exit 1
        echo "Done installing"
        exit 0
        ;;

    "uninstall")
        require_config || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE uninstall || exit 1
        if [ "$USER" = "root" ] && which ldconfig >/dev/null 2>&1; then
            ldconfig || exit 1
        fi
        echo "Done uninstalling"
        exit 0
        ;;

    "uninstall-prod")
        require_config || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE uninstall INSTALL_FILTER="shared-libs,progs" || exit 1
        if [ "$USER" = "root" ] && which ldconfig >/dev/null 2>&1; then
            ldconfig || exit 1
        fi
        echo "Done uninstalling"
        exit 0
        ;;

    "uninstall-devel")
        require_config || exit 1
        export REALM_HAVE_CONFIG="1"
        $MAKE uninstall INSTALL_FILTER="static-libs,dev-progs,headers" || exit 1
        echo "Done uninstalling"
        exit 0
        ;;

    "test-installed")
        require_config || exit 1
        install_bindir="$(get_config_param "INSTALL_BINDIR")" || exit 1
        path_list_prepend PATH "$install_bindir" || exit 1
        $MAKE -C "test-installed" clean || exit 1
        $MAKE -C "test-installed" check  || exit 1
        echo "Test passed"
        exit 0
        ;;

    "wipe-installed")
        if [ "$OS" = "Darwin" ]; then
            find /usr/ /Library/Java /System/Library/Java /Library/Python -ipath '*realm*' -delete || exit 1
        else
            find /usr/ -ipath '*realm*' -delete && ldconfig || exit 1
        fi
        exit 0
        ;;

    "src-dist"|"bin-dist")
        if [ "$MODE" = "bin-dist" ]; then
            PREBUILT_CORE="1"
        fi

        EXTENSION_AVAILABILITY_REQUIRED="1"
        if [ "$#" -eq 1 -a "$1" = "all" ]; then
            INCLUDE_EXTENSIONS="$EXTENSIONS"
            INCLUDE_PLATFORMS="$PLATFORMS"
        elif [ "$#" -eq 1 -a "$1" = "avail" ]; then
            INCLUDE_EXTENSIONS="$EXTENSIONS"
            INCLUDE_PLATFORMS="$PLATFORMS"
            EXTENSION_AVAILABILITY_REQUIRED=""
        elif [ "$#" -eq 1 -a "$1" = "none" ]; then
            INCLUDE_EXTENSIONS=""
            INCLUDE_PLATFORMS=""
        elif [ $# -ge 1 -a "$1" != "not" ]; then
            for x in "$@"; do
                found=""
                for y in $EXTENSIONS $PLATFORMS; do
                    if [ "$x" = "$y" ]; then
                        found="1"
                        break
                    fi
                done
                if ! [ "$found" ]; then
                    echo "Bad extension name '$x'" 1>&2
                    exit 1
                fi
            done
            INCLUDE_EXTENSIONS=""
            for x in $EXTENSIONS; do
                for y in "$@"; do
                    if [ "$x" = "$y" ]; then
                        word_list_append INCLUDE_EXTENSIONS "$x" || exit 1
                        break
                    fi
                done
            done
            INCLUDE_PLATFORMS=""
            for x in $PLATFORMS; do
                for y in "$@"; do
                    if [ "$x" = "$y" ]; then
                        word_list_append INCLUDE_PLATFORMS "$x" || exit 1
                        break
                    fi
                done
            done
        elif [ "$#" -ge 1 -a "$1" = "not" ]; then
            if [ "$#" -eq 1 ]; then
                echo "Please specify which extensions to exclude" 1>&2
                echo "Available extensions are: $EXTENSIONS $PLATFORMS" 1>&2
                exit 1
            fi
            shift
            for x in "$@"; do
                found=""
                for y in $EXTENSIONS $PLATFORMS; do
                    if [ "$x" = "$y" ]; then
                        found="1"
                        break
                    fi
                done
                if ! [ "$found" ]; then
                    echo "Bad extension name '$x'" 1>&2
                    exit 1
                fi
            done
            INCLUDE_EXTENSIONS=""
            for x in $EXTENSIONS; do
                found=""
                for y in "$@"; do
                    if [ "$x" = "$y" ]; then
                        found="1"
                        break
                    fi
                done
                if ! [ "$found" ]; then
                    word_list_append INCLUDE_EXTENSIONS "$x" || exit 1
                fi
            done
            INCLUDE_PLATFORMS=""
            for x in $PLATFORMS; do
                found=""
                for y in "$@"; do
                    if [ "$x" = "$y" ]; then
                        found="1"
                        break
                    fi
                done
                if ! [ "$found" ]; then
                    word_list_append INCLUDE_PLATFORMS "$x" || exit 1
                fi
            done
        else
            cat 1>&2 <<EOF
Please specify which extensions (and auxiliary platforms) to include:
  Specify 'all' to include all extensions.
  Specify 'avail' to include all available extensions.
  Specify 'none' to exclude all extensions.
  Specify 'EXT1  [EXT2]...' to include the specified extensions.
  Specify 'not  EXT1  [EXT2]...' to exclude the specified extensions.
Available extensions: $EXTENSIONS
Available auxiliary platforms: $PLATFORMS
EOF
            exit 1
        fi

        VERSION="$(git describe)" || exit 1
        if ! [ "$REALM_VERSION" ]; then
            REALM_VERSION="$(printf "%s\n" "$VERSION" | sed 's/^v//')" || exit 1
            export REALM_VERSION
        fi
        NAME="realm-$REALM_VERSION"

        TEMP_DIR="$(mktemp -d /tmp/realm.dist.XXXX)" || exit 1

        LOG_FILE="$TEMP_DIR/build-dist.log"
        log_message()
        {
            local msg
            msg="$1"
            printf "\n>>>>>>>> %s\n" "$msg" >> "$LOG_FILE"
        }
        message()
        {
            local msg
            msg="$1"
            log_message "$msg"
            printf "%s\n" "$msg"
        }
        warning()
        {
            local msg
            msg="$1"
            message "WARNING: $msg"
        }
        fatal()
        {
            local msg
            msg="$1"
            message "FATAL: $msg"
        }

        if (
            message "Log file is here: $LOG_FILE"
            message "Checking availability of extensions"
            failed=""
            AVAIL_EXTENSIONS=""
            for x in $INCLUDE_EXTENSIONS; do
                EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
                if ! [ -e "$EXT_HOME/build.sh" ]; then
                    if [ "$EXTENSION_AVAILABILITY_REQUIRED" ]; then
                        fatal "Missing extension '$EXT_HOME'"
                        failed="1"
                    else
                        warning "Missing extension '$EXT_HOME'"
                    fi
                    continue
                fi
                word_list_append AVAIL_EXTENSIONS "$x" || exit 1
            done
            # Checking that each extension is capable of copying
            # itself to the package
            FAKE_PKG_DIR="$TEMP_DIR/fake_pkg"
            mkdir "$FAKE_PKG_DIR" || exit 1
            NEW_AVAIL_EXTENSIONS=""
            for x in $AVAIL_EXTENSIONS; do
                EXT_DIR="$(map_ext_name_to_dir "$x")" || exit 1
                EXT_HOME="../$EXT_DIR"
                echo "Testing transfer of extension '$x' to package" >> "$LOG_FILE"
                mkdir "$FAKE_PKG_DIR/$EXT_DIR" || exit 1
                if ! sh "$EXT_HOME/build.sh" dist-copy "$FAKE_PKG_DIR/$EXT_DIR" >>"$LOG_FILE" 2>&1; then
                    if [ "$EXTENSION_AVAILABILITY_REQUIRED" ]; then
                        fatal "Transfer of extension '$x' to test package failed"
                        failed="1"
                    else
                        warning "Transfer of extension '$x' to test package failed"
                    fi
                    continue
                fi
                word_list_append NEW_AVAIL_EXTENSIONS "$x" || exit 1
            done
            if [ "$failed" ]; then
                exit 1;
            fi
            AVAIL_EXTENSIONS="$NEW_AVAIL_EXTENSIONS"


            # Check state of working directories
            if [ "$(git status --porcelain)" ]; then
                warning "Dirty working directory '../$(basename "$REALM_HOME")'"
            fi
            for x in $AVAIL_EXTENSIONS; do
                EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
                if [ "$(cd "$EXT_HOME" && git status --porcelain)" ]; then
                    warning "Dirty working directory '$EXT_HOME'"
                fi
            done

            INCLUDE_IPHONE=""
            for x in $INCLUDE_PLATFORMS; do
                if [ "$x" = "iphone" ]; then
                    INCLUDE_IPHONE="1"
                    break
                fi
            done

            message "Continuing with these parts:"
            {
                BRANCH="$(git rev-parse --abbrev-ref HEAD)" || exit 1
                platforms=""
                if [ "$INCLUDE_IPHONE" ]; then
                    platforms="+iphone"
                fi
                echo "core  ->  .  $BRANCH  $VERSION  $platforms"
                for x in $AVAIL_EXTENSIONS; do
                    EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
                    EXT_BRANCH="$(cd "$EXT_HOME" && git rev-parse --abbrev-ref HEAD)" || exit 1
                    EXT_VERSION="$(cd "$EXT_HOME" && git describe --always)" || exit 1
                    platforms=""
                    if [ "$INCLUDE_IPHONE" ]; then
                        for y in $IPHONE_EXTENSIONS; do
                            if [ "$x" = "$y" ]; then
                                platforms="+iphone"
                            fi
                        done
                    fi
                    echo "$x  ->  $EXT_HOME  $EXT_BRANCH  $EXT_VERSION  $platforms"
                done
            } >"$TEMP_DIR/continuing_with" || exit 1
            column -t "$TEMP_DIR/continuing_with" >"$TEMP_DIR/continuing_with2" || exit 1
            sed 's/^/  /' "$TEMP_DIR/continuing_with2" >"$TEMP_DIR/continuing_with3" || exit 1
            tee -a "$LOG_FILE" <"$TEMP_DIR/continuing_with3"

            # Setup package directory
            PKG_DIR="$TEMP_DIR/$NAME"
            mkdir "$PKG_DIR" || exit 1
            mkdir "$PKG_DIR/log" || exit 1

            AUGMENTED_EXTENSIONS="$AVAIL_EXTENSIONS"
            word_list_prepend AUGMENTED_EXTENSIONS "c++" || exit 1

            AUGMENTED_EXTENSIONS_IPHONE="c++"
            for x in $AVAIL_EXTENSIONS; do
                for y in $IPHONE_EXTENSIONS; do
                    if [ "$x" = "$y" ]; then
                        word_list_append AUGMENTED_EXTENSIONS_IPHONE "$x" || exit 1
                    fi
                done
            done

            cat >"$PKG_DIR/build" <<EOF
#!/bin/sh

REALM_ORIG_CWD="\$(pwd)" || exit 1
export ORIG_CWD

dir="\$(dirname "\$0")" || exit 1
cd "\$dir" || exit 1
REALM_DIST_HOME="\$(pwd)" || exit 1
export REALM_DIST_HOME

export REALM_VERSION="$REALM_VERSION"
export PREBUILT_CORE="$PREBUILT_CORE"
export DISABLE_CHEETAH_CODE_GEN="1"

EXTENSIONS="$AUGMENTED_EXTENSIONS"

if [ \$# -gt 0 -a "\$1" = "interactive" ]; then
    shift
    if [ \$# -eq 0 ]; then
        echo "At least one extension must be specified."
        echo "Available extensions: \$EXTENSIONS"
        exit 1
    fi
    EXT=""
    while [ \$# -gt 0 ]; do
        e=\$1
        if [ \$(echo \$EXTENSIONS | tr " " "\n" | grep -c \$e) -eq 0 ]; then
            echo "\$e is not an available extension."
            echo "Available extensions: \$EXTENSIONS"
            exit 1
        fi
        EXT="\$EXT \$e"
        shift
    done
    INTERACTIVE=1 sh build config \$EXT || exit 1
    INTERACTIVE=1 sh build build || exit 1
    sudo -p "Password for installation: " INTERACTIVE=1 sh build install || exit 1
    echo
    echo "Installation report"
    echo "-------------------"
    echo "The following files have been installed:"
    for x in \$EXT; do
        if [ "\$x" != "c++" -a "\$x" != "c" ]; then
            echo "\$x:"
            sh $debug realm_\$x/build.sh install-report
            if [ $? -eq 1 ]; then
                echo " no files has been installed."
            fi
        fi
    done

    echo
    echo "Examples can be copied to the folder realm_examples in your home directory (\$HOME)."
    echo "Do you wish to copy examples to your home directory (y/n)?"
    read answer
    if [ \$(echo \$answer | grep -c ^[yY]) -eq 1 ]; then
        mkdir -p \$HOME/realm_examples
        for x in \$EXT; do
            if [ "\$x" != "c++" -a "\$x" != "c" ]; then
                cp -a realm_\$x/examples \$HOME/realm_examples/\$x
            fi
        done
        if [ \$(echo \$EXT | grep -c c++) -eq 1 ]; then
            cp -a realm/examples \$HOME/realm_examples/c++
        fi
        if [ \$(echo \$EXT | grep -c java) -eq 1 ]; then
            find \$HOME/realm_examples/java -name build.xml -exec sed -i -e 's/value="\.\.\/\.\.\/lib"/value="\/usr\/local\/share\/java"/' \{\} \\;
            find \$HOME/realm_examples/java -name build.xml -exec sed -i -e 's/"jnipath" value=".*" \/>/"jnipath" value="\/Library\/Java\/Extensions" \/>/' \{\} \\;
        fi

        echo "Examples can be found in \$HOME/realm_examples."
        echo "Please consult the README.md files in each subdirectory for information"
        echo "on how to build and run the examples."
    fi
    exit 0
fi

if [ \$# -eq 1 -a "\$1" = "clean" ]; then
    sh realm/build.sh dist-clean || exit 1
    exit 0
fi

if [ \$# -eq 1 -a "\$1" = "build" ]; then
    sh realm/build.sh dist-build || exit 1
    exit 0
fi

if [ \$# -eq 1 -a "\$1" = "build-iphone" -a "$INCLUDE_IPHONE" ]; then
    sh realm/build.sh dist-build-iphone || exit 1
    exit 0
fi

if [ \$# -eq 1 -a "\$1" = "test" ]; then
    sh realm/build.sh dist-test || exit 1
    exit 0
fi

if [ \$# -eq 1 -a "\$1" = "test-debug" ]; then
    sh realm/build.sh dist-test-debug || exit 1
    exit 0
fi

if [ \$# -eq 1 -a "\$1" = "install" ]; then
    sh realm/build.sh dist-install || exit 1
    exit 0
fi

if [ \$# -eq 1 -a "\$1" = "test-installed" ]; then
    sh realm/build.sh dist-test-installed || exit 1
    exit 0
fi

if [ \$# -eq 1 -a "\$1" = "uninstall" ]; then
    sh realm/build.sh dist-uninstall \$EXTENSIONS || exit 1
    exit 0
fi

if [ \$# -ge 1 -a "\$1" = "config" ]; then
    shift
    if [ \$# -eq 1 -a "\$1" = "all" ]; then
        sh realm/build.sh dist-config \$EXTENSIONS || exit 1
        exit 0
    fi
    if [ \$# -eq 1 -a "\$1" = "none" ]; then
        sh realm/build.sh dist-config || exit 1
        exit 0
    fi
    if [ \$# -ge 1 ]; then
        all_found="1"
        for x in "\$@"; do
            found=""
            for y in \$EXTENSIONS; do
                if [ "\$y" = "\$x" ]; then
                    found="1"
                    break
                fi
            done
            if ! [ "\$found" ]; then
                echo "No such extension '\$x'" 1>&2
                all_found=""
                break
            fi
        done
        if [ "\$all_found" ]; then
            sh realm/build.sh dist-config "\$@" || exit 1
            exit 0
        fi
        echo 1>&2
    fi
fi

cat README 1>&2
exit 1
EOF
            chmod +x "$PKG_DIR/build"

            if ! [ "$INTERACTIVE" ]; then
                cat >"$PKG_DIR/README" <<EOF
Realm version $REALM_VERSION

Configure specific extensions:    ./build  config  EXT1  [EXT2]...
Configure all extensions:         ./build  config  all
Configure only the core library:  ./build  config  none
Start building from scratch:      ./build  clean
Build configured extensions:      ./build  build
Install what was built:           sudo  ./build  install
Check state of installation:      ./build  test-installed
Uninstall configured extensions:  sudo  ./build  uninstall

The following steps should generally suffice:

    ./build config all
    ./build build
    sudo ./build install

Available extensions are: ${AUGMENTED_EXTENSIONS:-None}

EOF
                if [ "$PREBUILT_CORE" ]; then
                    cat >>"$PKG_DIR/README" <<EOF
During installation, the prebuilt core library will be installed along
with all the extensions that were successfully built. The C++
extension is part of the core library, so the effect of including
'c++' in the 'config' step is simply to request that the C++ header
files (and other files needed for development) are to be installed.
EOF
                else
                    cat >>"$PKG_DIR/README" <<EOF
When building is requested, the core library will be built along with
all the extensions that you have configured. The C++ extension is part
of the core library, so the effect of including 'c++' in the 'config'
step is simply to request that the C++ header files (and other files
needed for development) are to be installed.

For information on prerequisites when building the core library, see
realm/README.md.
EOF
                fi

                cat >>"$PKG_DIR/README" <<EOF

For information on prerequisites of the each individual extension, see
the README.md file in the corresponding subdirectory.
EOF

                if [ "$INCLUDE_IPHONE" ]; then
                    cat >>"$PKG_DIR/README" <<EOF

To build Realm for iPhone, run the following command:

    ./build build-iphone

The following iPhone extensions are availble: ${AUGMENTED_EXTENSIONS_IPHONE:-None}

Files produced for extension EXT will be placed in a subdirectory
named "iphone-EXT".
EOF
                fi

                cat >>"$PKG_DIR/README" <<EOF

Note that each build step creates a new log file in the subdirectory
called "log". When contacting Realm at <support@realm.com> because
of a problem in the installation process, we recommend that you attach
all these log files as a bundle to your mail.
EOF

                for x in $AVAIL_EXTENSIONS; do
                    EXT_DIR="$(map_ext_name_to_dir "$x")" || exit 1
                    EXT_HOME="../$EXT_DIR"
                    if REMARKS="$(sh "$EXT_HOME/build.sh" dist-remarks 2>&1)"; then
                        cat >>"$PKG_DIR/README" <<EOF

Remarks for '$x':

$REMARKS
EOF
                    fi
                done
            fi

            export DISABLE_CHEETAH_CODE_GEN="1"

            mkdir "$PKG_DIR/realm" || exit 1
            if [ "$PREBUILT_CORE" ]; then
                message "Building core library"
                PREBUILD_DIR="$TEMP_DIR/prebuild"
                mkdir "$PREBUILD_DIR" || exit 1
                sh "$REALM_HOME/build.sh" dist-copy "$PREBUILD_DIR" >>"$LOG_FILE" 2>&1 || exit 1
                (cd "$PREBUILD_DIR" && sh build.sh config && sh build.sh build) >>"$LOG_FILE" 2>&1 || exit 1

                if [ "$INCLUDE_IPHONE" ]; then
                    message "Building core library for 'iphone'"
                    (cd "$PREBUILD_DIR" && sh build.sh build-iphone) >>"$LOG_FILE" 2>&1 || exit 1
                fi

                message "Transferring prebuilt core library to package"
                mkdir "$TEMP_DIR/transfer" || exit 1
                cat >"$TEMP_DIR/transfer/include" <<EOF
/README.*
/build.sh
/config
/Makefile
/src/generic.mk
/src/project.mk
/src/config.mk
/src/Makefile
/src/realm.hpp
/src/realm/Makefile
/src/realm/util/config.sh
/src/realm/config_tool.cpp
/test/Makefile
/test/util/Makefile
/test-installed
/doc
EOF
                INST_HEADERS="$(cd "$PREBUILD_DIR/src/realm" && REALM_HAVE_CONFIG="1" $MAKE --no-print-directory get-inst-headers)" || exit 1
                INST_LIBS="$(cd "$PREBUILD_DIR/src/realm" && REALM_HAVE_CONFIG="1" $MAKE --no-print-directory get-inst-libraries)" || exit 1
                INST_PROGS="$(cd "$PREBUILD_DIR/src/realm" && REALM_HAVE_CONFIG="1" $MAKE --no-print-directory get-inst-programs)" || exit 1
                for x in $INST_HEADERS $INST_LIBS $INST_PROGS; do
                    echo "/src/realm/$x" >> "$TEMP_DIR/transfer/include"
                done
                grep -E -v '^(#.*)?$' "$TEMP_DIR/transfer/include" >"$TEMP_DIR/transfer/include2" || exit 1
                sed -e 's/\([.\[^$]\)/\\\1/g' -e 's|\*|[^/]*|g' -e 's|^\([^/]\)|^\\(.*/\\)\\{0,1\\}\1|' -e 's|^/|^|' -e 's|$|\\(/.*\\)\\{0,1\\}$|' "$TEMP_DIR/transfer/include2" >"$TEMP_DIR/transfer/include.bre" || exit 1
                (cd "$PREBUILD_DIR" && find -L * -type f) >"$TEMP_DIR/transfer/files1" || exit 1
                grep -f "$TEMP_DIR/transfer/include.bre" "$TEMP_DIR/transfer/files1" >"$TEMP_DIR/transfer/files2" || exit 1
                (cd "$PREBUILD_DIR" && tar czf "$TEMP_DIR/transfer/core.tar.gz" -T "$TEMP_DIR/transfer/files2") || exit 1
                (cd "$PKG_DIR/realm" && tar xzmf "$TEMP_DIR/transfer/core.tar.gz") || exit 1
                if [ "$INCLUDE_IPHONE" ]; then
                    cp -R "$PREBUILD_DIR/$IPHONE_DIR" "$PKG_DIR/realm/" || exit 1
                fi
                get_host_info >"$PKG_DIR/realm/.PREBUILD_INFO" || exit 1

                message "Running test suite for core library"
                if ! (cd "$PREBUILD_DIR" && sh build.sh test) >>"$LOG_FILE" 2>&1; then
                    warning "Test suite failed for core library"
                fi

                message "Running test suite for core library in debug mode"
                if ! (cd "$PREBUILD_DIR" && sh build.sh test-debug) >>"$LOG_FILE" 2>&1; then
                    warning "Test suite failed for core library in debug mode"
                fi
            else
                message "Transferring core library to package"
                sh "$REALM_HOME/build.sh" dist-copy "$PKG_DIR/realm" >>"$LOG_FILE" 2>&1 || exit 1
            fi

            for x in $AVAIL_EXTENSIONS; do
                message "Transferring extension '$x' to package"
                EXT_DIR="$(map_ext_name_to_dir "$x")" || exit 1
                EXT_HOME="../$EXT_DIR"
                mkdir "$PKG_DIR/$EXT_DIR" || exit 1
                sh "$EXT_HOME/build.sh" dist-copy "$PKG_DIR/$EXT_DIR" >>"$LOG_FILE" 2>&1 || exit 1
            done

            message "Zipping the package"
            (cd "$TEMP_DIR" && tar czf "$NAME.tar.gz" "$NAME/") || exit 1

            message "Extracting the package for test"
            TEST_DIR="$TEMP_DIR/test"
            mkdir "$TEST_DIR" || exit 1
            (cd "$TEST_DIR" && tar xzmf "$TEMP_DIR/$NAME.tar.gz") || exit 1
            TEST_PKG_DIR="$TEST_DIR/$NAME"

            install_prefix="$TEMP_DIR/test-install"
            mkdir "$install_prefix" || exit 1

            export REALM_DIST_LOG_FILE="$LOG_FILE"
            export REALM_DIST_NONINTERACTIVE="1"
            export REALM_TEST_INSTALL_PREFIX="$install_prefix"

            error=""
            log_message "Testing './build config all'"
            if ! "$TEST_PKG_DIR/build" config all; then
                [ -e "$TEST_PKG_DIR/realm/.DIST_CORE_WAS_CONFIGURED" ] || exit 1
                error="1"
            fi

            log_message "Testing './build clean'"
            if ! "$TEST_PKG_DIR/build" clean; then
                error="1"
            fi

            log_message "Testing './build build'"
            if ! "$TEST_PKG_DIR/build" build; then
                [ -e "$TEST_PKG_DIR/realm/.DIST_CORE_WAS_BUILT" ] || exit 1
                error="1"
            fi

            log_message "Testing './build test'"
            if ! "$TEST_PKG_DIR/build" test; then
                error="1"
            fi

            log_message "Testing './build test-debug'"
            if ! "$TEST_PKG_DIR/build" test-debug; then
                error="1"
            fi

            log_message "Testing './build install'"
            if ! "$TEST_PKG_DIR/build" install; then
                [ -e "$TEST_PKG_DIR/realm/.DIST_CORE_WAS_INSTALLED" ] || exit 1
                error="1"
            fi

            # When testing against a prebuilt core library, we have to
            # work around the fact that it is not going to be
            # installed in the usual place. While the config programs
            # are rebuilt to reflect the unusual installation
            # directories, other programs (such as `realmd`) that
            # use the shared core library, are not, so we have to set
            # the runtime library path. Also, the core library will
            # look for `realmd` in the wrong place, so we have to
            # set `REALM_ASYNC_DAEMON` too.
            if [ "$PREBUILT_CORE" ]; then
                install_libdir="$(get_config_param "INSTALL_LIBDIR" "$TEST_PKG_DIR/realm")" || exit 1
                path_list_prepend "$LD_LIBRARY_PATH_NAME" "$install_libdir"  || exit 1
                export "$LD_LIBRARY_PATH_NAME"
                install_libexecdir="$(get_config_param "INSTALL_LIBEXECDIR" "$TEST_PKG_DIR/realm")" || exit 1
                export REALM_ASYNC_DAEMON="$install_libexecdir/realmd"
            fi

            log_message "Testing './build test-installed'"
            if ! "$TEST_PKG_DIR/build" test-installed; then
                error="1"
            fi

            # Copy the installation test directory to allow later inspection
            INSTALL_COPY="$TEMP_DIR/test-install-copy"
            cp -R "$REALM_TEST_INSTALL_PREFIX" "$INSTALL_COPY" || exit 1

            log_message "Testing './build uninstall'"
            if ! "$TEST_PKG_DIR/build" uninstall; then
                error="1"
            fi

            message "Checking that './build uninstall' leaves nothing behind"
            REMAINING_PATHS="$(cd "$REALM_TEST_INSTALL_PREFIX" && find * \! -type d -o -ipath '*realm*')" || exit 1
            if [ "$REMAINING_PATHS" ]; then
                fatal "Files and/or directories remain after uninstallation"
                printf "%s" "$REMAINING_PATHS" >>"$LOG_FILE"
                exit 1
            fi

            if [ "$INCLUDE_IPHONE" ]; then
                message "Testing platform 'iphone'"
                log_message "Testing './build build-iphone'"
                if ! "$TEST_PKG_DIR/build" build-iphone; then
                    error="1"
                fi
            fi

#            if [ "$error" ]; then
#                exit 1
#            fi

            exit 0

        ); then
            message 'SUCCESS!'
            message "Log file is here: $LOG_FILE"
            message "Package is here: $TEMP_DIR/$NAME.tar.gz"
            if [ "$PREBUILT_CORE" ]; then
                message "Distribution type: BINARY (prebuilt core library)"
            else
                message "Distribution type: SOURCE"
            fi
        else
            message 'FAILED!' 1>&2
            message "Log file is here: $LOG_FILE"
            exit 1
        fi
        exit 0
        ;;


#    "dist-check-avail")
#        for x in $EXTENSIONS; do
#            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
#            if [ -e "$EXT_HOME/build.sh" ]; then
#                echo ">>>>>>>> CHECKING AVAILABILITY OF '$x'"
#                if sh "$EXT_HOME/build.sh" check-avail; then
#                    echo 'YES!'
#                fi
#            fi
#        done
#        exit 0
#        ;;


    "dist-config")
        TEMP_DIR="$(mktemp -d /tmp/realm.dist-config.XXXX)" || exit 1
        if ! which "make" >/dev/null 2>&1; then
            echo "ERROR: GNU make must be installed."
            if [ "$OS" = "Darwin" ]; then
                echo "Please install xcode and command-line tools and try again."
                echo "You can download them at https://developer.apple.com/downloads/index.action"
                echo "or consider to use https://github.com/kennethreitz/osx-gcc-installer"
            fi
            exit 1
        fi
        LOG_FILE="$(get_dist_log_path "config" "$TEMP_DIR")" || exit 1
        (
            echo "Realm version: ${REALM_VERSION:-Unknown}"
            if [ -e ".PREBUILD_INFO" ]; then
                echo
                echo "PREBUILD HOST INFO:"
                cat ".PREBUILD_INFO"
            fi
            echo
            echo "BUILD HOST INFO:"
            get_host_info || exit 1
            echo
            get_compiler_info || exit 1
            echo
        ) >>"$LOG_FILE"
        ERROR=""
        rm -f ".DIST_CORE_WAS_CONFIGURED" || exit 1
        # When configuration is tested in the context of building a
        # distribution package, we have to reconfigure the core
        # library such that it will install into the temporary
        # directory (an unfortunate and ugly kludge).
        if [ "$PREBUILT_CORE" ] && ! [ "$REALM_TEST_INSTALL_PREFIX" ]; then
            touch ".DIST_CORE_WAS_CONFIGURED" || exit 1
        else
            if ! [ "$INTERACTIVE" ]; then
                if [ "$PREBUILT_CORE" ]; then
                    echo "RECONFIGURING Prebuilt core library (only for testing)" | tee -a "$LOG_FILE"
                else
                    echo "CONFIGURING Core library" | tee -a "$LOG_FILE"
                fi
            fi
            if [ "$INTERACTIVE" ]; then
                if ! sh "build.sh" config $REALM_TEST_INSTALL_PREFIX 2>&1 | tee -a "$LOG_FILE"; then
                    ERROR="1"
                fi
            else
                if ! sh "build.sh" config $REALM_TEST_INSTALL_PREFIX >>"$LOG_FILE" 2>&1; then
                    ERROR="1"
                fi
            fi
            if ! [ "$ERROR" ]; then
                # At this point we have to build the config commands
                # `realm-config` and `realm-config-dbg` such that
                # they are available during configuration and building
                # of extensions, just as if the core library has been
                # previously installed.
                if ! sh "build.sh" build-config-progs >>"$LOG_FILE" 2>&1; then
                    ERROR="1"
                fi
            fi
            if [ "$ERROR" ]; then
                echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
            else
                touch ".DIST_CORE_WAS_CONFIGURED" || exit 1
            fi
        fi
        # Copy the core library config programs into a dedicated
        # directory such that they are retained across 'clean'
        # operations.
        mkdir -p "config-progs" || exit 1
        for x in "realm-config" "realm-config-dbg"; do
            rm -f "config-progs/$x" || exit 1
            cp "src/realm/$x" "config-progs/" || exit 1
        done
        if ! [ "$ERROR" ]; then
            mkdir "$TEMP_DIR/select" || exit 1
            for x in "$@"; do
                touch "$TEMP_DIR/select/$x" || exit 1
            done
            rm -f ".DIST_CXX_WAS_CONFIGURED" || exit 1
            if [ -e "$TEMP_DIR/select/c++" ]; then
                if [ "$INTERACTIVE" ]; then
                    echo "Configuring extension 'c++'" | tee -a "$LOG_FILE"
                else
                    echo "CONFIGURING Extension 'c++'" | tee -a "$LOG_FILE"
                fi
                touch ".DIST_CXX_WAS_CONFIGURED" || exit 1
            fi
            export REALM_DIST_INCLUDEDIR="$REALM_HOME/src"
            export REALM_DIST_LIBDIR="$REALM_HOME/src/realm"
            path_list_prepend PATH "$REALM_HOME/config-progs" || exit 1
            export PATH
            for x in $EXTENSIONS; do
                EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
                rm -f "$EXT_HOME/.DIST_WAS_CONFIGURED" || exit 1
                if [ -e "$TEMP_DIR/select/$x" ]; then
                    if [ "$INTERACTIVE" ]; then
                        echo "Configuring extension '$x'" | tee -a "$LOG_FILE"
                    else
                        echo "CONFIGURING Extension '$x'" | tee -a "$LOG_FILE"
                    fi
                    if [ "$INTERACTIVE" ]; then
                        if sh "$EXT_HOME/build.sh" config $REALM_TEST_INSTALL_PREFIX 2>&1 | tee -a "$LOG_FILE"; then
                            touch "$EXT_HOME/.DIST_WAS_CONFIGURED" || exit 1
                        else
                            ERROR="1"
                        fi
                    else
                        if sh "$EXT_HOME/build.sh" config $REALM_TEST_INSTALL_PREFIX >>"$LOG_FILE" 2>&1; then
                            touch "$EXT_HOME/.DIST_WAS_CONFIGURED" || exit 1
                        else
                            echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                            ERROR="1"
                        fi
                    fi
                fi
            done
            if ! [ "$INTERACTIVE" ]; then
                echo "DONE CONFIGURING" | tee -a "$LOG_FILE"
            fi
        fi
        if ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
            if ! [ "$INTERACTIVE" ]; then
                if [ "$ERROR" ]; then
                    cat 1>&2 <<EOF

Note: Some parts could not be configured. You may be missing one or
more dependencies. Check the README file for details. If that does not
help, check the log file.
The log file is here: $LOG_FILE
EOF
                fi
                cat <<EOF

Run the following command to build the parts that were successfully
configured:

    ./build build

EOF
            fi
        fi
        if [ "$ERROR" ] && ! [ "$INTERACTIVE" ]; then
            exit 1
        fi
        exit 0
        ;;


    "dist-clean")
        if ! [ -e ".DIST_CORE_WAS_CONFIGURED" ]; then
            cat 1>&2 <<EOF
ERROR: Nothing was configured.
You need to run './build config' first.
EOF
            exit 1
        fi
        TEMP_DIR="$(mktemp -d /tmp/realm.dist-clean.XXXX)" || exit 1
        LOG_FILE="$(get_dist_log_path "clean" "$TEMP_DIR")" || exit 1
        ERROR=""
        rm -f ".DIST_CORE_WAS_BUILT" || exit 1
        if ! [ "$PREBUILT_CORE" ]; then
            echo "CLEANING Core library" | tee -a "$LOG_FILE"
            if ! sh "build.sh" clean >>"$LOG_FILE" 2>&1; then
                echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                ERROR="1"
            fi
        fi
        for x in $EXTENSIONS; do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/.DIST_WAS_CONFIGURED" ]; then
                echo "CLEANING Extension '$x'" | tee -a "$LOG_FILE"
                rm -f "$EXT_HOME/.DIST_WAS_BUILT" || exit 1
                if ! sh "$EXT_HOME/build.sh" clean >>"$LOG_FILE" 2>&1; then
                    echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                    ERROR="1"
                fi
            fi
        done
        if ! [ "$INTERACTIVE" ]; then
            echo "DONE CLEANING" | tee -a "$LOG_FILE"
        fi
        if [ "$ERROR" ] && ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
            echo "Log file is here: $LOG_FILE" 1>&2
        fi
        if [ "$ERROR" ]; then
            exit 1
        fi
        exit 0
        ;;


    "dist-build")
        if ! [ -e ".DIST_CORE_WAS_CONFIGURED" ]; then
            cat 1>&2 <<EOF
ERROR: Nothing was configured.
You need to run './build config' first.
EOF
            exit 1
        fi
        TEMP_DIR="$(mktemp -d /tmp/realm.dist-build.XXXX)" || exit 1
        LOG_FILE="$(get_dist_log_path "build" "$TEMP_DIR")" || exit 1
        (
            echo "Realm version: ${REALM_VERSION:-Unknown}"
            if [ -e ".PREBUILD_INFO" ]; then
                echo
                echo "PREBUILD HOST INFO:"
                cat ".PREBUILD_INFO"
            fi
            echo
            echo "BUILD HOST INFO:"
            get_host_info || exit 1
            echo
            get_compiler_info || exit 1
            echo
        ) >>"$LOG_FILE"
        rm -f ".DIST_CORE_WAS_BUILT" || exit 1
        if [ "$PREBUILT_CORE" ]; then
            touch ".DIST_CORE_WAS_BUILT" || exit 1
            if [ "$INTERACTIVE" ]; then
                echo "Building core library"
            fi
        else
            if [ "$INTERACTIVE" ]; then
                echo "Building c++ library" | tee -a "$LOG_FILE"
            else
                echo "BUILDING Core library" | tee -a "$LOG_FILE"
            fi
            if sh "build.sh" build >>"$LOG_FILE" 2>&1; then
                touch ".DIST_CORE_WAS_BUILT" || exit 1
            else
                if [ "$INTERACTIVE" ]; then
                    echo '  > Failed!' | tee -a "$LOG_FILE"
                else
                    echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                fi
                if ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
                    cat 1>&2 <<EOF

Note: The core library could not be built. You may be missing one or
more dependencies. Check the README file for details. If this does not
help, check the log file.
The log file is here: $LOG_FILE
EOF
                fi
                exit 1
            fi
        fi
        for x in $EXTENSIONS; do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/.DIST_WAS_CONFIGURED" ]; then
                if [ "$INTERACTIVE" ]; then
                    echo "Building extension '$x'" | tee -a "$LOG_FILE"
                else
                    echo "BUILDING Extension '$x'" | tee -a "$LOG_FILE"
                fi
                rm -f "$EXT_HOME/.DIST_WAS_BUILT" || exit 1
                if sh "$EXT_HOME/build.sh" build >>"$LOG_FILE" 2>&1; then
                    touch "$EXT_HOME/.DIST_WAS_BUILT" || exit 1
                else
                    if [ "$INTERACTIVE" ]; then
                        echo '  > Failed!' | tee -a "$LOG_FILE"
                    else
                        echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                    fi
                    ERROR="1"
                fi
            fi
        done
        if [ "$INTERACTIVE" ]; then
            echo "Done building" | tee -a "$LOG_FILE"
        else
            echo "DONE BUILDING" | tee -a "$LOG_FILE"
        fi
        if ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
            if ! [ "$INTERACTIVE" ]; then
                if [ "$ERROR" ]; then
                    cat 1>&2 <<EOF

Note: Some parts failed to build. You may be missing one or more
dependencies. Check the README file for details. If this does not
help, check the log file.
The log file is here: $LOG_FILE

EOF
                fi
                cat <<EOF

Run the following command to install the parts that were successfully
built:

    sudo ./build install

EOF
            fi
        fi
        if [ "$ERROR" ]; then
            exit 1
        fi
        exit 0
        ;;


    "dist-build-iphone")
        if ! [ -e ".DIST_CORE_WAS_CONFIGURED" ]; then
            cat 1>&2 <<EOF
ERROR: Nothing was configured.
You need to run './build config' first.
EOF
            exit 1
        fi
        dist_home="$REALM_HOME"
        if [ "$REALM_DIST_HOME" ]; then
            dist_home="$REALM_DIST_HOME"
        fi
        TEMP_DIR="$(mktemp -d /tmp/realm.dist-build-iphone.XXXX)" || exit 1
        LOG_FILE="$(get_dist_log_path "build-iphone" "$TEMP_DIR")" || exit 1
        (
            echo "Realm version: ${REALM_VERSION:-Unknown}"
            if [ -e ".PREBUILD_INFO" ]; then
                echo
                echo "PREBUILD HOST INFO:"
                cat ".PREBUILD_INFO"
            fi
            echo
            echo "BUILD HOST INFO:"
            get_host_info || exit 1
            echo
            get_compiler_info || exit 1
            echo
        ) >>"$LOG_FILE"
        rm -f ".DIST_CORE_WAS_BUILT_FOR_IPHONE" || exit 1
        if [ "$PREBUILT_CORE" ]; then
            touch ".DIST_CORE_WAS_BUILT_FOR_IPHONE" || exit 1
        else
            echo "BUILDING Core library for iPhone" | tee -a "$LOG_FILE"
            if sh "build.sh" build-iphone >>"$LOG_FILE" 2>&1; then
                touch ".DIST_CORE_WAS_BUILT_FOR_IPHONE" || exit 1
            else
                echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                if ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
                    cat 1>&2 <<EOF

Note: You may be missing one or more dependencies. Check the README
file for details. If this does not help, check the log file.
The log file is here: $LOG_FILE
EOF
                fi
                exit 1
            fi
        fi
        if [ -e ".DIST_CXX_WAS_CONFIGURED" ]; then
            mkdir -p "$dist_home/iphone-c++" || exit 1
            cp -R "$IPHONE_DIR"/* "$dist_home/iphone-c++/" || exit 1
        fi
        for x in $IPHONE_EXTENSIONS; do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/.DIST_WAS_CONFIGURED" ]; then
                echo "BUILDING Extension '$x' for iPhone" | tee -a "$LOG_FILE"
                rm -f "$EXT_HOME/.DIST_WAS_BUILT_FOR_IPHONE" || exit 1
                if sh "$EXT_HOME/build.sh" build-iphone >>"$LOG_FILE" 2>&1; then
                    mkdir -p "$dist_home/iphone-$x" || exit 1
                    cp -R "$EXT_HOME/$IPHONE_DIR"/* "$dist_home/iphone-$x/" || exit 1
                    touch "$EXT_HOME/.DIST_WAS_BUILT_FOR_IPHONE" || exit 1
                else
                    echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                    ERROR="1"
                fi
            fi
        done
        if ! [ "$INTERACTIVE" ]; then
            echo "DONE BUILDING" | tee -a "$LOG_FILE"
        fi
        if ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
            if [ "$ERROR" ]; then
                cat 1>&2 <<EOF

Note: Some parts failed to build. You may be missing one or more
dependencies. Check the README file for details. If this does not
help, check the log file.
The log file is here: $LOG_FILE

Files produced for a successfully built extension EXT have been placed
in a subdirectory named "iphone-EXT".
EOF
            else
                cat <<EOF

Files produced for extension EXT have been placed in a subdirectory
named "iphone-EXT".
EOF
            fi
        fi
        if [ "ERROR" ]; then
            exit 1
        fi
        exit 0
        ;;


    "dist-test"|"dist-test-debug")
        test_mode="test"
        test_msg="TESTING %s"
        async_daemon="realmd"
        if [ "$MODE" = "dist-test-debug" ]; then
            test_mode="test-debug"
            test_msg="TESTING %s in debug mode"
            async_daemon="realmd-dbg"
        fi
        if ! [ -e ".DIST_CORE_WAS_BUILT" ]; then
            cat 1>&2 <<EOF
ERROR: Nothing to test.
You need to run './build build' first.
EOF
            exit 1
        fi
        TEMP_DIR="$(mktemp -d /tmp/realm.dist-$test_mode.XXXX)" || exit 1
        LOG_FILE="$(get_dist_log_path "$test_mode" "$TEMP_DIR")" || exit 1
        (
            echo "Realm version: ${REALM_VERSION:-Unknown}"
            if [ -e ".PREBUILD_INFO" ]; then
                echo
                echo "PREBUILD HOST INFO:"
                cat ".PREBUILD_INFO"
            fi
            echo
            echo "BUILD HOST INFO:"
            get_host_info || exit 1
            echo
        ) >>"$LOG_FILE"
        ERROR=""
        if ! [ "$PREBUILT_CORE" ]; then
            printf "$test_msg\n" "Core library" | tee -a "$LOG_FILE"
            if ! sh "build.sh" "$test_mode" >>"$LOG_FILE" 2>&1; then
                echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                ERROR="1"
            fi
        fi
        # We set `LD_LIBRARY_PATH` and `REALM_ASAYNC_DAEMON` here to be able
        # to test extensions before installation of the core library.
        path_list_prepend "$LD_LIBRARY_PATH_NAME" "$REALM_HOME/src/realm"  || exit 1
        export "$LD_LIBRARY_PATH_NAME"
        export REALM_ASYNC_DAEMON="$REALM_HOME/src/realm/$async_daemon"
        for x in $EXTENSIONS; do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/.DIST_WAS_BUILT" ]; then
                printf "$test_msg\n" "Extension '$x'" | tee -a "$LOG_FILE"
                if ! sh "$EXT_HOME/build.sh" "$test_mode" >>"$LOG_FILE" 2>&1; then
                    echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                    ERROR="1"
                fi
            fi
        done
        if ! [ "$INTERACTIVE" ]; then
            echo "DONE TESTING" | tee -a "$LOG_FILE"
        fi
        if [ "$ERROR" ] && ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
            echo "Log file is here: $LOG_FILE" 1>&2
        fi
        if [ "$ERROR" ]; then
            exit 1
        fi
        exit 0
        ;;

    "dist-install")
        if ! [ -e ".DIST_CORE_WAS_BUILT" ]; then
            cat 1>&2 <<EOF
ERROR: Nothing to install.
You need to run './build build' first.
EOF
            exit 1
        fi
        TEMP_DIR="$(mktemp -d /tmp/realm.dist-install.XXXX)" || exit 1
        chmod a+rx "$TEMP_DIR" || exit 1
        LOG_FILE="$(get_dist_log_path "install" "$TEMP_DIR")" || exit 1
        touch "$LOG_FILE" || exit 1
        chmod a+r "$LOG_FILE" || exit 1
        (
            echo "Realm version: ${REALM_VERSION:-Unknown}"
            if [ -e ".PREBUILD_INFO" ]; then
                echo
                echo "PREBUILD HOST INFO:"
                cat ".PREBUILD_INFO"
            fi
            echo
            echo "BUILD HOST INFO:"
            get_host_info || exit 1
            echo
        ) >>"$LOG_FILE"
        ERROR=""
        NEED_USR_LOCAL_LIB_NOTE=""
        if ! [ "$INTERACTIVE" ]; then
            echo "INSTALLING Core library" | tee -a "$LOG_FILE"
        fi
        if sh build.sh install-prod >>"$LOG_FILE" 2>&1; then
            touch ".DIST_CORE_WAS_INSTALLED" || exit 1
            if [ -e ".DIST_CXX_WAS_CONFIGURED" ]; then
                if [ "$INTERACTIVE" ]; then
                    echo "Installing 'c++' (core)" | tee -a "$LOG_FILE"
                else
                    echo "INSTALLING Extension 'c++'" | tee -a "$LOG_FILE"
                fi
                if sh build.sh install-devel >>"$LOG_FILE" 2>&1; then
                    touch ".DIST_CXX_WAS_INSTALLED" || exit 1
                    NEED_USR_LOCAL_LIB_NOTE="$PLATFORM_HAS_LIBRARY_PATH_ISSUE"
                else
                    if [ "$INTERACTIVE" ]; then
                        echo '  > Failed!' | tee -a "$LOG_FILE"
                    else
                        echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                    fi
                    ERROR="1"
                fi
            fi
            for x in $EXTENSIONS; do
                EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
                if [ -e "$EXT_HOME/.DIST_WAS_CONFIGURED" -a -e "$EXT_HOME/.DIST_WAS_BUILT" ]; then
                    if [ "$INTERACTIVE" ]; then
                        echo "Installing extension '$x'" | tee -a "$LOG_FILE"
                    else
                        echo "INSTALLING Extension '$x'" | tee -a "$LOG_FILE"
                    fi
                    if sh "$EXT_HOME/build.sh" install >>"$LOG_FILE" 2>&1; then
                        touch "$EXT_HOME/.DIST_WAS_INSTALLED" || exit 1
                        if [ "$x" = "c" -o "$x" = "objc" ]; then
                            NEED_USR_LOCAL_LIB_NOTE="$PLATFORM_HAS_LIBRARY_PATH_ISSUE"
                        fi
                    else
                        if [ "$INTERACTIVE" ]; then
                            echo '  > Failed!' | tee -a "$LOG_FILE"
                        else
                            echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                        fi
                        ERROR="1"
                    fi
                fi
            done
            if [ "$NEED_USR_LOCAL_LIB_NOTE" ] && ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
                libdir="$(get_config_param "INSTALL_LIBDIR")" || exit 1
                cat <<EOF

NOTE: Shared libraries have been installed in '$libdir'.

We believe that on your system this directory is not part of the
default library search path. If this is true, you probably have to do
one of the following things to successfully use Realm in a C, C++,
or Objective-C application:

 - Either run 'export LD_RUN_PATH=$libdir' before building your
   application.

 - Or run 'export LD_LIBRARY_PATH=$libdir' before launching your
   application.

 - Or add '$libdir' to the system-wide library search path by editing
   /etc/ld.so.conf.

EOF
            fi
            if ! [ "$INTERACTIVE" ]; then
                echo "DONE INSTALLING" | tee -a "$LOG_FILE"
            fi
        else
            echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
            ERROR="1"
        fi
        if ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
            if [ "$ERROR" ]; then
                echo "Log file is here: $LOG_FILE" 1>&2
            else
                if ! [ "$INTERACTIVE" ]; then
                    cat <<EOF

At this point you should run the following command to check that all
installed parts are working properly. If any parts failed to install,
they will be skipped during this test:

    ./build test-installed

EOF
                fi
            fi
        fi
        if [ "$ERROR" ]; then
            exit 1
        fi
        exit 0
        ;;


    "dist-uninstall")
        if ! [ -e ".DIST_CORE_WAS_CONFIGURED" ]; then
            cat 1>&2 <<EOF
ERROR: Nothing was configured.
You need to run './build config' first.
EOF
            exit 1
        fi
        TEMP_DIR="$(mktemp -d /tmp/realm.dist-uninstall.XXXX)" || exit 1
        chmod a+rx "$TEMP_DIR" || exit 1
        LOG_FILE="$(get_dist_log_path "uninstall" "$TEMP_DIR")" || exit 1
        touch "$LOG_FILE" || exit 1
        chmod a+r "$LOG_FILE" || exit 1
        (
            echo "Realm version: ${REALM_VERSION:-Unknown}"
            if [ -e ".PREBUILD_INFO" ]; then
                echo
                echo "PREBUILD HOST INFO:"
                cat ".PREBUILD_INFO"
            fi
            echo
            echo "BUILD HOST INFO:"
            get_host_info || exit 1
            echo
        ) >>"$LOG_FILE"
        ERROR=""
        for x in $(word_list_reverse $EXTENSIONS); do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/.DIST_WAS_CONFIGURED" ]; then
                echo "UNINSTALLING Extension '$x'" | tee -a "$LOG_FILE"
                if ! sh "$EXT_HOME/build.sh" uninstall >>"$LOG_FILE" 2>&1; then
                    echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                    ERROR="1"
                fi
                rm -f "$EXT_HOME/.DIST_WAS_INSTALLED" || exit 1
            fi
        done
        if [ -e ".DIST_CXX_WAS_CONFIGURED" ]; then
            echo "UNINSTALLING Extension 'c++'" | tee -a "$LOG_FILE"
            if ! sh build.sh uninstall-devel >>"$LOG_FILE" 2>&1; then
                echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                ERROR="1"
            fi
            rm -f ".DIST_CXX_WAS_INSTALLED" || exit 1
        fi
        echo "UNINSTALLING Core library" | tee -a "$LOG_FILE"
        if ! sh build.sh uninstall-prod >>"$LOG_FILE" 2>&1; then
            echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
            ERROR="1"
        fi
        rm -f ".DIST_CORE_WAS_INSTALLED" || exit 1
        echo "DONE UNINSTALLING" | tee -a "$LOG_FILE"
        if [ "$ERROR" ] && ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
            echo "Log file is here: $LOG_FILE" 1>&2
        fi
        if [ "$ERROR" ]; then
             exit 1
        fi
        exit 0
        ;;


    "dist-test-installed")
        if ! [ -e ".DIST_CORE_WAS_INSTALLED" ]; then
            cat 1>&2 <<EOF
ERROR: Nothing was installed.
You need to run 'sudo ./build install' first.
EOF
            exit 1
        fi
        TEMP_DIR="$(mktemp -d /tmp/realm.dist-test-installed.XXXX)" || exit 1
        LOG_FILE="$(get_dist_log_path "test-installed" "$TEMP_DIR")" || exit 1
        (
            echo "Realm version: ${REALM_VERSION:-Unknown}"
            if [ -e ".PREBUILD_INFO" ]; then
                echo
                echo "PREBUILD HOST INFO:"
                cat ".PREBUILD_INFO"
            fi
            echo
            echo "BUILD HOST INFO:"
            get_host_info || exit 1
            echo
            get_compiler_info || exit 1
            echo
        ) >>"$LOG_FILE"
        ERROR=""
        if [ -e ".DIST_CXX_WAS_INSTALLED" ]; then
            echo "TESTING Installed extension 'c++'" | tee -a "$LOG_FILE"
            if sh build.sh test-installed >>"$LOG_FILE" 2>&1; then
                echo 'Success!' | tee -a "$LOG_FILE"
            else
                echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                ERROR="1"
            fi
        fi
        for x in $EXTENSIONS; do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/.DIST_WAS_INSTALLED" ]; then
                echo "TESTING Installed extension '$x'" | tee -a "$LOG_FILE"
                if sh "$EXT_HOME/build.sh" test-installed >>"$LOG_FILE" 2>&1; then
                    echo 'Success!' | tee -a "$LOG_FILE"
                else
                    echo 'Failed!' | tee -a "$LOG_FILE" 1>&2
                    ERROR="1"
                fi
            fi
        done
        if ! [ "$INTERACTIVE" ]; then
            echo "DONE TESTING" | tee -a "$LOG_FILE"
        fi
        if [ "$ERROR" ] && ! [ "$REALM_DIST_NONINTERACTIVE" ]; then
            echo "Log file is here: $LOG_FILE" 1>&2
        fi
        if [ "$ERROR" ]; then
            exit 1
        fi
        exit 0
        ;;


    "dist-status")
        echo ">>>>>>>> STATUS OF 'realm'"
        git status
        for x in $EXTENSIONS; do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/build.sh" ]; then
                echo ">>>>>>>> STATUS OF '$EXT_HOME'"
                (cd "$EXT_HOME/"; git status)
            fi
        done
        exit 0
        ;;


    "dist-pull")
        echo ">>>>>>>> PULLING 'realm'"
        git pull
        for x in $EXTENSIONS; do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/build.sh" ]; then
                echo ">>>>>>>> PULLING '$EXT_HOME'"
                (cd "$EXT_HOME/"; git pull)
            fi
        done
        exit 0
        ;;


    "dist-checkout")
        if [ "$#" -ne 1 ]; then
            echo "Please specify what you want to checkout" 1>&2
            exit 1
        fi
        WHAT="$1"
        echo ">>>>>>>> CHECKING OUT '$WHAT' OF 'realm'"
        git checkout "$WHAT"
        for x in $EXTENSIONS; do
            EXT_HOME="../$(map_ext_name_to_dir "$x")" || exit 1
            if [ -e "$EXT_HOME/build.sh" ]; then
                echo ">>>>>>>> CHECKING OUT '$WHAT' OF '$EXT_HOME'"
                (cd "$EXT_HOME/"; git checkout "$WHAT")
            fi
        done
        exit 0
        ;;

    "dist-copy")
        # Copy to distribution package
        TARGET_DIR="$1"
        if ! [ "$TARGET_DIR" -a -d "$TARGET_DIR" ]; then
            echo "Unspecified or bad target directory '$TARGET_DIR'" 1>&2
            exit 1
        fi
        TEMP_DIR="$(mktemp -d /tmp/realm.copy.XXXX)" || exit 1
        cat >"$TEMP_DIR/include" <<EOF
/README.md
/build.sh
/Makefile
/src
/test
/test-installed
/doc
EOF
        cat >"$TEMP_DIR/exclude" <<EOF
.gitignore
/test/test-*
/test/benchmark-*
/test/performance
/test/experiments
/doc/development
EOF
        grep -E -v '^(#.*)?$' "$TEMP_DIR/include" >"$TEMP_DIR/include2" || exit 1
        grep -E -v '^(#.*)?$' "$TEMP_DIR/exclude" >"$TEMP_DIR/exclude2" || exit 1
        sed -e 's/\([.\[^$]\)/\\\1/g' -e 's|\*|[^/]*|g' -e 's|^\([^/]\)|^\\(.*/\\)\\{0,1\\}\1|' -e 's|^/|^|' -e 's|$|\\(/.*\\)\\{0,1\\}$|' "$TEMP_DIR/include2" >"$TEMP_DIR/include.bre" || exit 1
        sed -e 's/\([.\[^$]\)/\\\1/g' -e 's|\*|[^/]*|g' -e 's|^\([^/]\)|^\\(.*/\\)\\{0,1\\}\1|' -e 's|^/|^|' -e 's|$|\\(/.*\\)\\{0,1\\}$|' "$TEMP_DIR/exclude2" >"$TEMP_DIR/exclude.bre" || exit 1
        git ls-files >"$TEMP_DIR/files1" || exit 1
        grep -f "$TEMP_DIR/include.bre" "$TEMP_DIR/files1" >"$TEMP_DIR/files2" || exit 1
        grep -v -f "$TEMP_DIR/exclude.bre" "$TEMP_DIR/files2" >"$TEMP_DIR/files3" || exit 1
        tar czf "$TEMP_DIR/archive.tar.gz" -T "$TEMP_DIR/files3" || exit 1
        (cd "$TARGET_DIR" && tar xzmf "$TEMP_DIR/archive.tar.gz") || exit 1
        if ! [ "$REALM_DISABLE_MARKDOWN_CONVERT" ]; then
            (cd "$TARGET_DIR" && pandoc README.md -o README.pdf) || exit 1
        fi
        exit 0
        ;;

    "build-arm-benchmark")
        CC=arm-linux-gnueabihf-gcc AR=arm-linux-gnueabihf-ar LD=arm-linux-gnueabihf-g++ make benchmark-common-tasks COMPILER_IS_GCC_LIKE=1 LD_IS_GCC_LIKE=1 EXTRA_CFLAGS=-mthumb
        ;;

    "jenkins-pull-request")
        # Run by Jenkins for each pull request whenever it changes
        if ! [ -d "$WORKSPACE" ]; then
            echo "Bad or unspecified Jenkins workspace '$WORKSPACE'" 1>&2
            exit 1
        fi

        git reset --hard || exit 1
        git clean -xfd || exit 1

        REALM_MAX_BPNODE_SIZE_DEBUG="4" REALM_ENABLE_ENCRYPTION="yes" sh build.sh config "$WORKSPACE/install" || exit 1
        sh build.sh build-ios || exit 1
        sh build.sh build-android || exit 1
        UNITTEST_ENCRYPT_ALL=yes sh build.sh check || exit 1

        REALM_MAX_BPNODE_SIZE_DEBUG="4" sh build.sh config "$WORKSPACE/install" || exit 1
        sh build.sh build-ios || exit 1
        sh build.sh build-android || exit 1
        sh build.sh build || exit 1
        UNITTEST_SHUFFLE="1" UNITTEST_RANDOM_SEED="random" UNITTEST_THREADS="1" UNITTEST_XML="1" sh build.sh check-debug || exit 1
        sh build.sh install || exit 1
        (
            cd "examples" || exit 1
            make || exit 1
            ./tutorial || exit 1
            ./mini_tutorial || exit 1
            (
                cd "demo" || exit 1
                make || exit 1
            ) || exit 1
        ) || exit 1
        exit 0
        ;;

    "jenkins-pipeline-unit-tests")
        # Run by Jenkins as part of the core pipeline whenever master changes.
        check_mode="$1"
        if [ "$check_mode" != "check" -a "$check_mode" != "check-debug" ]; then
            echo "Bad check mode '$check_mode'" 1>&2
            exit 1
        fi
        REALM_MAX_BPNODE_SIZE_DEBUG="4" sh build.sh config || exit 1
        UNITTEST_SHUFFLE="1" UNITTEST_RANDOM_SEED="random" UNITTEST_XML="1" sh build.sh "$check_mode" || exit 1
        exit 0
        ;;

    "jenkins-pipeline-coverage")
        # Run by Jenkins as part of the core pipeline whenever master changes
        REALM_MAX_BPNODE_SIZE_DEBUG="4" sh build.sh config || exit 1
        sh build.sh gcovr || exit 1
        exit 0
        ;;

    "jenkins-pipeline-address-sanitizer")
        # Run by Jenkins as part of the core pipeline whenever master changes.
        REALM_MAX_BPNODE_SIZE_DEBUG="4" sh build.sh config || exit 1
        sh build.sh asan-debug || exit 1
        exit 0
        ;;

    "jenkins-pipeline-thread-sanitizer")
        # Run by Jenkins as part of the core pipeline whenever master changes.
        REALM_MAX_BPNODE_SIZE_DEBUG="4" sh build.sh config || exit 1
        sh build.sh tsan-debug || exit 1
        exit 0
        ;;

    "jenkins-valgrind")
        # Run by Jenkins. Relies on the WORKSPACE environment variable provided by Jenkins itself
        REALM_ENABLE_ALLOC_SET_ZERO=1 sh build.sh config || exit 1
        sh build.sh clean || exit 1
        VALGRIND_FLAGS="--tool=memcheck --leak-check=full --undef-value-errors=yes --track-origins=yes --child-silent-after-fork=no --trace-children=yes --xml=yes --suppressions=${WORKSPACE}/test/valgrind.suppress --xml-file=${WORKSPACE}/realm-tests-dbg.%p.memreport" sh build.sh memcheck || exit 1
        exit 0
        ;;

    *)
        usage
        exit 1
        ;;
esac
