# Build libtailscale (Go c-archive) when QUACKSCALE_WITH_TAILSCALE is enabled.

if(NOT QUACKSCALE_WITH_TAILSCALE)
    return()
endif()

# libtailscale go.mod requires Go 1.25+. DuckDB extension CI Docker images ship Go 1.20.5
# when extra_toolchains includes go; bootstrap a matching toolchain when the host `go` is too old.
set(QUACKSCALE_GO_VERSION "1.25.5" CACHE STRING "Go toolchain version used to build libtailscale")
set(QUACKSCALE_GO_MIN_MAJOR 1)
set(QUACKSCALE_GO_MIN_MINOR 25)

set(LIBTAILSCALE_SOURCE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/third_party/libtailscale")
if(NOT EXISTS "${LIBTAILSCALE_SOURCE_DIR}/tailscale.go")
    message(FATAL_ERROR "libtailscale sources not found at ${LIBTAILSCALE_SOURCE_DIR}. "
                        "Run: git submodule update --init --recursive")
endif()

if(CMAKE_HOST_SYSTEM_NAME STREQUAL "Darwin")
    set(_quackscale_go_os "darwin")
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Linux")
    set(_quackscale_go_os "linux")
elseif(CMAKE_HOST_SYSTEM_NAME STREQUAL "Windows")
    set(_quackscale_go_os "windows")
else()
    message(FATAL_ERROR "Unsupported host OS for libtailscale Go bootstrap: ${CMAKE_HOST_SYSTEM_NAME}")
endif()

if(CMAKE_HOST_SYSTEM_PROCESSOR MATCHES "aarch64|ARM64|arm64")
    set(_quackscale_go_arch "arm64")
else()
    set(_quackscale_go_arch "amd64")
endif()

set(_quackscale_go_toolchain_dir
    "${CMAKE_BINARY_DIR}/third_party/go-toolchain/go${QUACKSCALE_GO_VERSION}.${_quackscale_go_os}-${_quackscale_go_arch}")
if(_quackscale_go_os STREQUAL "windows")
    set(_quackscale_go_executable "${_quackscale_go_toolchain_dir}/go/bin/go.exe")
    set(_quackscale_go_archive_ext "zip")
else()
    set(_quackscale_go_executable "${_quackscale_go_toolchain_dir}/go/bin/go")
    set(_quackscale_go_archive_ext "tar.gz")
endif()

function(_quackscale_go_version_ok go_executable out_var)
    execute_process(
        COMMAND "${go_executable}" version
        OUTPUT_VARIABLE _gov
        ERROR_VARIABLE _goerr
        OUTPUT_STRIP_TRAILING_WHITESPACE
        RESULT_VARIABLE _goresult)
    if(NOT _goresult EQUAL 0)
        set(${out_var} FALSE PARENT_SCOPE)
        return()
    endif()
    if(_gov MATCHES "go version go([0-9]+)\\.([0-9]+)")
        set(_maj "${CMAKE_MATCH_1}")
        set(_min "${CMAKE_MATCH_2}")
        if(_maj GREATER QUACKSCALE_GO_MIN_MAJOR)
            set(${out_var} TRUE PARENT_SCOPE)
        elseif(_maj EQUAL QUACKSCALE_GO_MIN_MAJOR AND _min GREATER_EQUAL QUACKSCALE_GO_MIN_MINOR)
            set(${out_var} TRUE PARENT_SCOPE)
        else()
            set(${out_var} FALSE PARENT_SCOPE)
        endif()
    else()
        set(${out_var} FALSE PARENT_SCOPE)
    endif()
endfunction()

set(QUACKSCALE_GO_EXECUTABLE "")
find_program(_quackscale_system_go go)
if(_quackscale_system_go)
    _quackscale_go_version_ok("${_quackscale_system_go}" _quackscale_system_go_ok)
    if(_quackscale_system_go_ok)
        set(QUACKSCALE_GO_EXECUTABLE "${_quackscale_system_go}")
        message(STATUS "Using system Go for libtailscale: ${QUACKSCALE_GO_EXECUTABLE}")
    endif()
endif()

if(NOT QUACKSCALE_GO_EXECUTABLE)
    if(NOT EXISTS "${_quackscale_go_executable}")
        set(_quackscale_go_archive_name "go${QUACKSCALE_GO_VERSION}.${_quackscale_go_os}-${_quackscale_go_arch}.${_quackscale_go_archive_ext}")
        set(_quackscale_go_archive_url "https://go.dev/dl/${_quackscale_go_archive_name}")
        set(_quackscale_go_archive "${CMAKE_BINARY_DIR}/third_party/go-download/${_quackscale_go_archive_name}")
        file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/third_party/go-download")
        message(STATUS "Downloading Go ${QUACKSCALE_GO_VERSION} for libtailscale: ${_quackscale_go_archive_url}")
        file(DOWNLOAD "${_quackscale_go_archive_url}" "${_quackscale_go_archive}" STATUS _quackscale_dl_status SHOW_PROGRESS)
        list(GET _quackscale_dl_status 0 _quackscale_dl_code)
        if(NOT _quackscale_dl_code EQUAL 0)
            list(GET _quackscale_dl_status 1 _quackscale_dl_msg)
            message(FATAL_ERROR "Failed to download Go toolchain (${_quackscale_dl_code}): ${_quackscale_dl_msg}")
        endif()
        file(MAKE_DIRECTORY "${_quackscale_go_toolchain_dir}")
        if(_quackscale_go_os STREQUAL "windows")
            file(ARCHIVE_EXTRACT INPUT "${_quackscale_go_archive}" DESTINATION "${_quackscale_go_toolchain_dir}")
        else()
            execute_process(
                COMMAND tar -xzf "${_quackscale_go_archive}" -C "${_quackscale_go_toolchain_dir}"
                RESULT_VARIABLE _quackscale_tar_result)
            if(NOT _quackscale_tar_result EQUAL 0)
                message(FATAL_ERROR "Failed to extract Go toolchain archive (exit ${_quackscale_tar_result})")
            endif()
        endif()
        if(NOT EXISTS "${_quackscale_go_executable}")
            message(FATAL_ERROR "Go bootstrap failed: ${_quackscale_go_executable} not found after extract")
        endif()
    endif()
    set(QUACKSCALE_GO_EXECUTABLE "${_quackscale_go_executable}")
    message(STATUS "Using bootstrapped Go for libtailscale: ${QUACKSCALE_GO_EXECUTABLE}")
endif()

set(LIBTAILSCALE_BUILD_DIR "${CMAKE_BINARY_DIR}/third_party/libtailscale")
set(LIBTAILSCALE_ARCHIVE "${LIBTAILSCALE_BUILD_DIR}/libtailscale.a")

file(MAKE_DIRECTORY "${LIBTAILSCALE_BUILD_DIR}")

set(_libtailscale_go_env "CGO_ENABLED=1")
if(APPLE)
    set(_libtailscale_go_env "${_libtailscale_go_env}" "MACOSX_DEPLOYMENT_TARGET=11.0")
endif()

add_custom_command(
    OUTPUT "${LIBTAILSCALE_ARCHIVE}"
    COMMAND ${CMAKE_COMMAND} -E env ${_libtailscale_go_env}
            "${QUACKSCALE_GO_EXECUTABLE}" build -buildmode=c-archive -o "${LIBTAILSCALE_ARCHIVE}"
    WORKING_DIRECTORY "${LIBTAILSCALE_SOURCE_DIR}"
    DEPENDS
        "${LIBTAILSCALE_SOURCE_DIR}/tailscale.go"
        "${LIBTAILSCALE_SOURCE_DIR}/tailscale.c"
        "${LIBTAILSCALE_SOURCE_DIR}/go.mod"
    COMMENT "Building libtailscale.a with Go ${QUACKSCALE_GO_VERSION}"
    VERBATIM
)

add_custom_target(libtailscale_archive DEPENDS "${LIBTAILSCALE_ARCHIVE}")

set(QUACKSCALE_LIBTAILSCALE_ARCHIVE "${LIBTAILSCALE_ARCHIVE}")
set(QUACKSCALE_LIBTAILSCALE_INCLUDE "${LIBTAILSCALE_SOURCE_DIR}")
