cmake_minimum_required(VERSION 3.13)
project(SonicMania)

option(WITH_RSDK "Whether or not to build with RSDKv5. Defaults to true" ON)

# ------------------------------------------------------------------
# MiSTer port profile (Phase 0 — cross-compile plumbing).
#
# PORT_MISTER gates a profile that forces SDL2 subsystem, SDL audio,
# disables Plus/DLC content, and forces static-linking of the game so the
# engine ships as a single RSDKv5U executable. The profile is inert on
# non-MiSTer builds (everything else falls through to upstream defaults).
#
# ENABLE_PERF_TELEMETRY is declared at top-level (NOT inside PORT_MISTER)
# so `cmake -DENABLE_PERF_TELEMETRY=OFF` is always respected at configure
# time regardless of PORT_MISTER. In Phase 0 the define is a no-op; real
# perf-gating arrives in Phase 6.
# ------------------------------------------------------------------
option(PORT_MISTER "Enable MiSTer-oriented build profile" OFF)
option(ENABLE_PERF_TELEMETRY "Enable perf telemetry capture (no-op in Phase 0)" ON)

if(PORT_MISTER)
    # M5 sidestep: the `option(GAME_STATIC ...)` call below (line ~48 in
    # this file, inherited from upstream) uses a nested generator expression
    # as its default value:
    #     option(GAME_STATIC "..." $<BOOL:$<IF:WITH_RSDK,ON,OFF>>)
    # Generator expressions are not evaluated during `option()` processing —
    # they only expand at generate time inside target properties. So that
    # default is effectively the literal unevaluated string, which CMake
    # coerces to a boolean of unpredictable truthiness depending on the
    # cmake version and prior cache state. The genex is upstream's bug, not
    # ours; we deliberately do NOT patch the upstream line (keeps future
    # submodule merges clean). Instead we force GAME_STATIC=ON into the
    # cache BEFORE `add_subdirectory(${RSDK_PATH})` runs, so the engine
    # submodule picks up our value rather than the broken default.
    # TODO(phase-7): file this upstream against RSDKv5-Decompilation and,
    # once they either remove the genex or swap it for a plain ON/OFF, drop
    # this FORCE override and the sibling forces below.
    set(GAME_STATIC ON CACHE STRING "force-static for MiSTer" FORCE)
    # Phase 1: select the MiSTer native render backend (RETRO_SUBSYSTEM=MiSTer
    # -> RSDK_USE_MISTER=1 via dependencies/RSDKv5/CMakeLists.txt:155 ->
    # RETRO_RENDERDEVICE_MISTER=1 in RetroEngine.hpp). The subsystem string is
    # also re-FORCEd inside platforms/MiSTer.cmake as belt-and-braces.
    set(RETRO_SUBSYSTEM "MiSTer" CACHE STRING "MiSTer: native render backend" FORCE)
    set(USE_SDL_AUDIO ON CACHE BOOL "MiSTer: force SDL audio" FORCE)
    set(RETRO_DISABLE_PLUS ON CACHE BOOL "MiSTer: disable Plus/DLC content gating" FORCE)
    set(PLATFORM "MiSTer" CACHE STRING "MiSTer: platform dispatch" FORCE)
endif()

message(STATUS "PORT_MISTER=${PORT_MISTER}")
message(STATUS "ENABLE_PERF_TELEMETRY=${ENABLE_PERF_TELEMETRY}")

if(NOT DEFINED GAME_STATIC)
    if(WIN32)
        set(GAME_STATIC OFF)
    elseif(UNIX)
        set(GAME_STATIC OFF)
    else()
        set(GAME_STATIC ON)
    endif()
endif()

option(GAME_STATIC "Whether or not to build the game as a static library." $<BOOL:$<IF:WITH_RSDK,ON,OFF>>)

option(MANIA_FIRST_RELEASE "Whether or not to build Mania's first release. Defaults to false" OFF)
if(MANIA_FIRST_RELEASE)
    set(MANIA_PREPLUS ON)
else()
    option(MANIA_PREPLUS "Whether or not to build Mania pre-plus. Defaults to false" OFF)
endif()


if(NOT MANIA_PREPLUS)
    set(GAME_VERSION 6 CACHE STRING "The game version to use. Defaults to 6 == Last Steam release")
else()
    set(GAME_VERSION 3 CACHE STRING "The game version to use. Defaults to 3 == Last pre-plus release")
endif()

set(GAME_NAME "SonicMania" CACHE STRING "The game directory to look into")
set(GAME_OUTPUT_NAME "Game" CACHE STRING "The name of the built library")

option(GAME_INCLUDE_EDITOR "Whether or not to include editor functions. Defaults to true" ON)

option(GAME_INCREMENTAL_BUILD "Whether or not to build all objects separately (for quicker dev-->build iterations). Defaults to false." OFF)

if(GAME_INCREMENTAL_BUILD)
    include(${GAME_NAME}/Objects.cmake)
    set(GAME_SOURCES
        ${GAME_NAME}/Game.c
        ${GENERATED_SOURCES}
    )
else()
    set(GAME_SOURCES
        ${GAME_NAME}/Game.c
        ${GAME_NAME}/Objects/All.c
    )
endif()

if(GAME_STATIC)
    add_library(${GAME_NAME} STATIC ${GAME_SOURCES})
else()
    add_library(${GAME_NAME} SHARED ${GAME_SOURCES})
endif()

target_include_directories(${GAME_NAME} PRIVATE
    ${GAME_NAME}/
    ${GAME_NAME}/Objects/
)

if(WIN32)
    target_compile_definitions(${GAME_NAME} PRIVATE _CRT_SECURE_NO_WARNINGS)
endif()

set_target_properties(${GAME_NAME} PROPERTIES OUTPUT_NAME ${GAME_OUTPUT_NAME})

if(WITH_RSDK)
    set(RSDK_PATH dependencies/RSDKv5 CACHE STRING "The path to look for RSDKv5 if using WITH_RSDK.")

    add_subdirectory(${RSDK_PATH})

    if(GAME_STATIC)
        target_include_directories(RetroEngine PRIVATE ${GAME_NAME}/)
        target_link_libraries(RetroEngine ${GAME_NAME})
    endif()
else()
    set(RETRO_REVISION 3 CACHE STRING "What revision to compile for. Defaults to v5U = 3")

    option(RETRO_MOD_LOADER "Enables or disables the mod loader." ON)
    set(RETRO_MOD_LOADER_VER 2 CACHE STRING "Sets the mod loader version. Defaults to latest")

    target_compile_definitions(${GAME_NAME} PRIVATE
        RETRO_REVISION=${RETRO_REVISION}

        RETRO_USE_MOD_LOADER=$<BOOL:${RETRO_MOD_LOADER}>
        RETRO_MOD_LOADER_VER=${RETRO_MOD_LOADER_VER}

        GAME_INCLUDE_EDITOR=$<BOOL:${GAME_INCLUDE_EDITOR}>

        MANIA_PREPLUS=$<BOOL:${MANIA_PREPLUS}>
        MANIA_FIRST_RELEASE=$<BOOL:${MANIA_FIRST_RELEASE}>
        GAME_VERSION=${GAME_VERSION}
    )
endif()

# MSVC likes to merge similar functions together even though their addresses are being referenced.
# Disable COMDAT folding to fix some bugs like not drowning when suspended to a pull chain in HCZ.
if(MSVC)
    target_link_options(${GAME_NAME} PRIVATE /OPT:NOICF)
endif()
