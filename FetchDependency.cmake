# Minimum CMake version required. Currently driven by the use of GET_MESSAGE_LOG_LEVEL:
# https://cmake.org/cmake/help/latest/command/cmake_language.html#get-message-log-level
set(FetchDependencyMinimumVersion "3.25")
if(${CMAKE_VERSION} VERSION_LESS ${FetchDependencyMinimumVersion})
  message(FATAL_ERROR "FetchDependency requires CMake ${FetchDependencyMinimumVersion} (currently using ${CMAKE_VERSION}).")
endif()

set(FetchDependencyMajorVersion "0")
set(FetchDependencyMinorVersion "1")
set(FetchDependencyPatchVersion "1")
set(FetchDependencyVersion "${FetchDependencyMajorVersion}.${FetchDependencyMinorVersion}.${FetchDependencyPatchVersion}")

function(_fd_run)
  cmake_parse_arguments(FDR "" "WORKING_DIRECTORY;OUT_COMMAND;OUTPUT_VARIABLE;ERROR_VARIABLE;ERROR_CONTEXT" "COMMAND" ${ARGN})
  if(NOT FDR_WORKING_DIRECTORY)
    set(FDR_WORKING_DIRECTORY "")
  endif()

  cmake_language(GET_MESSAGE_LOG_LEVEL Level)
  if((${Level} STREQUAL "VERBOSE") OR (${Level} STREQUAL "DEBUG") OR (${Level} STREQUAL "TRACE"))
    set(EchoCommand "STDOUT")
    set(EchoOutput "ECHO_OUTPUT_VARIABLE")
    set(EchoError "ECHO_ERROR_VARIABLE")
  else()
    set(EchoCommand "NONE")
  endif()

  execute_process(
    COMMAND ${FDR_COMMAND}
    OUTPUT_VARIABLE Output
    ERROR_VARIABLE Error
    RESULT_VARIABLE Result
    WORKING_DIRECTORY "${FDR_WORKING_DIRECTORY}"
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_STRIP_TRAILING_WHITESPACE
    COMMAND_ECHO ${EchoCommand}
    ${EchoOutput}
    ${EchoError}
  )

  if(FDR_OUT_COMMAND)
    string(JOIN " " OutputCommand ${FDR_COMMAND})
    set(${FDR_OUT_COMMAND} ${OutputCommand} PARENT_SCOPE)
  endif()

  if(Result)
    if(FDR_ERROR_VARIABLE)
      set(${FDR_ERROR_VARIABLE} ${Error} PARENT_SCOPE)
    else()
      message(FATAL_ERROR "${FDR_ERROR_CONTEXT}${Output}\n${Error}")
    endif()
  endif()

  if(FDR_OUTPUT_VARIABLE)
    set(${FDR_OUTPUT_VARIABLE} ${Output} PARENT_SCOPE)
  endif()
endfunction()

function(_fd_find FDF_NAME)
  cmake_parse_arguments(FDF "" "ROOT" "PATHS" ${ARGN})
  set(SavedPrefixPath ${CMAKE_PREFIX_PATH})
  set(CMAKE_PREFIX_PATH "${FDF_PATHS}")
  find_package(${FDF_NAME} REQUIRED PATHS ${FDF_ROOT})
  set(CMAKE_PREFIX_PATH ${SavedPrefixPath})
endfunction()

function(fetch_dependency FD_NAME)
  cmake_parse_arguments(FD
    "FETCH_ONLY"
    "ROOT;GIT_REPOSITORY;GIT_TAG;LOCAL_SOURCE;PACKAGE_NAME;CONFIGURATION;CMAKELIST_SUBDIRECTORY;OUT_SOURCE_DIR;OUT_BINARY_DIR"
    "GENERATE_OPTIONS;BUILD_OPTIONS"
    ${ARGN}
  )

  if($ENV{FETCH_DEPENDENCY_FAST})
    set(FastMode ON)
    message(STATUS "Checking dependency ${FD_NAME} (fast)")
  else()
    set(FastMode OFF)
    message(STATUS "Checking dependency ${FD_NAME}")
  endif()

  # Process the source arguments.
  set(SourceMode "")
  if(FD_LOCAL_SOURCE)
    if(FD_GIT_REPOSITORY)
      message(AUTHOR_WARNING "LOCAL_SOURCE and GIT_REPOSITORY are mutually exlusive; LOCAL_SOURCE will be used.")
    endif()

    if(FD_GIT_TAG)
      message(AUTHOR_WARNING "GIT_TAG is ignored when LOCAL_SOURCE is provided.")
    endif()

    set(SourceMode "local")
  elseif(FD_GIT_REPOSITORY)
    if(NOT FD_GIT_TAG)
      message(FATAL_ERROR "GIT_TAG must be provided.")
    endif()

    set(SourceMode "git")
  else()
    message(FATAL_ERROR "One of LOCAL_SOURCE or GIT_REPOSITORY must be provided.")
  endif()

  if(NOT FD_PACKAGE_NAME)
    set(FD_PACKAGE_NAME "${FD_NAME}")
  endif()

  if(NOT FD_ROOT)
    if(FETCH_DEPENDENCY_DEFAULT_ROOT)
      set(FD_ROOT "${FETCH_DEPENDENCY_DEFAULT_ROOT}")
    else()
      set(FD_ROOT "External")
    endif()
  endif()

  # If FD_ROOT is a relative path, it is interpreted as being relative to the current binary directory.
  cmake_path(IS_RELATIVE FD_ROOT IsRootRelative)
  if(IsRootRelative)
    cmake_path(APPEND CMAKE_BINARY_DIR ${FD_ROOT} OUTPUT_VARIABLE FD_ROOT)
  endif()
  message(VERBOSE "  Using root: ${FD_ROOT}")

  if(NOT FD_CONFIGURATION)
    set(FD_CONFIGURATION "Release")
  endif()

  set(ProjectDirectory "${FD_ROOT}/${FD_NAME}")
  if("${SourceMode}" STREQUAL "local")
    set(SourceDirectory "${FD_LOCAL_SOURCE}")
  else()
    set(SourceDirectory "${ProjectDirectory}/Source")
  endif()

  set(BuildDirectory "${ProjectDirectory}/Build")
  set(PackageDirectory "${ProjectDirectory}/Package")
  set(StateDirectory "${ProjectDirectory}/State")

  # The version file tracks the version of FetchDependency that last processed the dependency.
  set(VersionFilePath "${StateDirectory}/version.txt")
  
  # The options file tracks the fetch_dependency() parameters that impact build or configuration in order to determine
  # when a rebuild is required.
  set(OptionsFilePath "${StateDirectory}/options.txt")

  # The configure and build script files track the commands executed for the given step.
  set(StepScriptFilePath "${CMAKE_CURRENT_FUNCTION_LIST_DIR}/Steps/step.in")
  if(UNIX)
    set(StepScriptHeader "#!/bin/sh")
    set(ConfigureScriptFilePath "${StateDirectory}/configure.sh")
    set(BuildScriptFilePath "${StateDirectory}/build.sh")
  else()
    set(StepScriptHeader "@echo off")
    set(ConfigureScriptFilePath "${StateDirectory}/configure.bat")
    set(BuildScriptFilePath "${StateDirectory}/build.bat")
  endif()

  # The manifest file contains the package directories of every dependency fetched for the calling project so far.
  set(ManifestFile "FetchedDependencies.txt")
  set(ManifestFilePath "${CMAKE_BINARY_DIR}/${ManifestFile}")

  list(APPEND FETCH_DEPENDENCY_PACKAGES "${PackageDirectory}")

  if(FD_OUT_SOURCE_DIR)
    set(${FD_OUT_SOURCE_DIR} "${SourceDirectory}" PARENT_SCOPE)
  endif()

  if(FD_OUT_BINARY_DIR)
    set(${FD_OUT_BINARY_DIR} "${BuildDirectory}" PARENT_SCOPE)
  endif()

  set(BuildNeededMessage "")

  # Check the version stamp. If this dependency was last processed with a version of FetchDependency with a different
  # major or minor version, the binary and package directories should be erased so that the dependency is rebuilt from
  # a clean state. This doesn't affect the source directory.
  if(EXISTS ${VersionFilePath})
    file(READ ${VersionFilePath} LastVersion)
    string(REGEX MATCH "^([0-9]+)\\.([0-9]+)\\.([0-9]+)" LastVersionMatch ${LastVersion})

    # Match 0 is the full match, 1-3 are the sub-matches for the major, minor and patch components.
    if(NOT ("${CMAKE_MATCH_1}" STREQUAL "${FetchDependencyMajorVersion}" AND "${CMAKE_MATCH_2}" STREQUAL "${FetchDependencyMinorVersion}"))
      message(STATUS "Clearing build cache (last built with ${LastVersionMatch}, now on ${FetchDependencyVersion}).")

      message(VERBOSE "Removing directory ${BuildDirectory}")
      file(REMOVE_RECURSE "${BuildDirectory}")

      message(VERBOSE "Removing directory ${PackageDirectory}")
      file(REMOVE_RECURSE "${PackageDirectory}")

      set(BuildNeededMessage "FetchDependency version changed")
    endif()
  endif()

  set(RequiredOptions "LOCAL_SOURCE=${FD_LOCAL_SOURCE}\nGIT_REPOSITORY=${FD_GIT_REPOSITORY}\nGIT_TAG=${FD_GIT_TAG}\nPACKAGE_NAME=${FD_PACKAGE_NAME}\nTOOLCHAIN=${CMAKE_TOOLCHAIN_FILE}\nCONFIGURATION=${FD_CONFIGURATION}\nCONFIGURE_OPTIONS=${FD_GENERATE_OPTIONS}\nBUILD_OPTIONS=${FD_BUILD_OPTIONS}\nCMAKELIST_SUBDIRECTORY=${FD_CMAKELIST_SUBDIRECTORY}\n")
  string(STRIP "${RequiredOptions}" RequiredOptions)
  if("${BuildNeededMessage}" STREQUAL "")
    # Assume the options differ, and clear this string only if they actually match.
    set(BuildNeededMessage "options differ")
    if(EXISTS ${OptionsFilePath})
      file(READ ${OptionsFilePath} ExistingOptions)
      string(STRIP "${ExistingOptions}" ExistingOptions)
      if("${ExistingOptions}" STREQUAL "${RequiredOptions}")
        set(BuildNeededMessage "")
      else()
        message(VERBOSE "Removing directory ${BuildDirectory}")
        file(REMOVE_RECURSE "${BuildDirectory}")
        message(VERBOSE "Removing directory ${PackageDirectory}")
        file(REMOVE_RECURSE "${PackageDirectory}")
      endif()
    endif()
  endif()

  if("${SourceMode}" STREQUAL "git")
    # Ensure the source directory exists and is up to date.
    set(IsFetchRequired FALSE)
    if(NOT IS_DIRECTORY "${SourceDirectory}")
      _fd_run(COMMAND git clone --recurse-submodules ${FD_GIT_REPOSITORY} "${SourceDirectory}")
    elseif(NOT FastMode)
      # If the directory exists, before doing anything else, make sure the it is in a clean state. Any local changes are
      # assumed to be intentional and prevent attempts to update.
      _fd_run(COMMAND git status --porcelain WORKING_DIRECTORY "${SourceDirectory}" OUTPUT_VARIABLE GitStatus)
      if(NOT "${GitStatus}" STREQUAL "")
        message(AUTHOR_WARNING "Source has local changes; update suppressed (${SourceDirectory}).")
      else()
        # Determine what the required version refers to in order to decide if we need to fetch from the remote or not.
        _fd_run(COMMAND git show-ref ${FD_GIT_TAG} WORKING_DIRECTORY "${SourceDirectory}" OUTPUT_VARIABLE ShowRefOutput ERROR_VARIABLE ShowRefError)
        if(${ShowRefOutput} MATCHES "^[a-z0-9]+[ \\t]+refs/(remotes|tags)/")
          # The version is a branch name (with remote) or a tag. The underlying commit can move, so a fetch is required.
          set(IsFetchRequired TRUE)
        elseif(${ShowRefOutput} MATCHES "^[a-z0-9]+[ \\t]+refs/heads/")
          # The version is a branch name without a remote. We don't allow this; the remote name must be specified.
          message(FATAL_ERROR "GIT_TAG must include a remote when referring to branch (e.g., 'origin/branch' instead of 'branch').")
        else()
          # The version is a commit hash. This is the ideal case, because if the current and required commits match we can
          # skip the fetch entirely.
          _fd_run(COMMAND git rev-parse HEAD^0 WORKING_DIRECTORY "${SourceDirectory}" OUTPUT_VARIABLE ExistingCommit)
          _fd_run(COMMAND git rev-parse ${FD_GIT_TAG}^0 WORKING_DIRECTORY "${SourceDirectory}" OUTPUT_VARIABLE RequiredCommit ERROR_VARIABLE RevParseError)
          if(NOT "${ExistingCommit}" STREQUAL "${RequiredCommit}")
            # They don't match, so we have to fetch.
            set(IsFetchRequired TRUE)
          endif()
        endif()

        if(IsFetchRequired)
          _fd_run(COMMAND git fetch --tags WORKING_DIRECTORY "${SourceDirectory}")
          _fd_run(COMMAND git submodule update --remote WORKING_DIRECTORY "${SourceDirectory}")
        endif()
      endif()
    endif()

    _fd_run(COMMAND git rev-parse HEAD^0 WORKING_DIRECTORY "${SourceDirectory}" OUTPUT_VARIABLE ExistingCommit)
    _fd_run(COMMAND git rev-parse ${FD_GIT_TAG}^0 WORKING_DIRECTORY "${SourceDirectory}" OUTPUT_VARIABLE RequiredCommit)
    if(NOT "${ExistingCommit}" STREQUAL "${RequiredCommit}")
      _fd_run(COMMAND git -c advice.detachedHead=false checkout --recurse-submodules ${FD_GIT_TAG} WORKING_DIRECTORY "${SourceDirectory}")
      set(BuildNeededMessage "versions differ")
    endif()
  elseif("${SourceMode}" STREQUAL "local")
    set(BuildNeededMessage "local source")
  endif()

  if(NOT FD_FETCH_ONLY)
    if(NOT FastMode)
      if(NOT "${BuildNeededMessage}" STREQUAL "")
        message(STATUS "Building (${BuildNeededMessage}).")

        list(APPEND ConfigureArguments "-DCMAKE_INSTALL_PREFIX=${PackageDirectory}")
        list(APPEND ConfigureArguments ${FD_GENERATE_OPTIONS})
        list(APPEND BuildArguments ${FD_BUILD_OPTIONS})

        if(CMAKE_TOOLCHAIN_FILE)
          list(APPEND ConfigureArguments " --toolchain ${CMAKE_TOOLCHAIN_FILE}")
        endif()

        # Configuration handling differs for single- versus multi-config generators.
        get_property(IsMultiConfig GLOBAL PROPERTY GENERATOR_IS_MULTI_CONFIG)
        if(IsMultiConfig)
          list(APPEND BuildArguments "--config ${FD_CONFIGURATION}")
        else()
          list(APPEND ConfigureArguments "-DCMAKE_BUILD_TYPE=${FD_CONFIGURATION}")
        endif()

        # When invoking CMake for the builds, the package paths are passed via the CMAKE_PREFIX_PATH environment variable.
        # This avoids a warning that would otherwise be generated if the dependency never actually caused
        # CMAKE_PREFIX_PATH to be referenced. Note that the platform path delimiter must be used to separate individual
        # paths in the environment variable.
        set(Packages ${FETCH_DEPENDENCY_PACKAGES})
        if(UNIX)
          string(REPLACE ";" ":" Packages "${Packages}")
        endif()
        set(ENV{CMAKE_PREFIX_PATH} "${Packages}")

        # Configure, build and install the dependency.
        _fd_run(
          COMMAND "${CMAKE_COMMAND}" -G ${CMAKE_GENERATOR} -S "${SourceDirectory}/${FD_CMAKELIST_SUBDIRECTORY}" -B "${BuildDirectory}" ${ConfigureArguments}
          OUT_COMMAND StepCommand
          ERROR_CONTEXT "Configure failed: "
        )
        configure_file(
          "${StepScriptFilePath}"
          "${ConfigureScriptFilePath}"
          FILE_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_WRITE GROUP_EXECUTE WORLD_READ
        )

        _fd_run(
          COMMAND "${CMAKE_COMMAND}" --build "${BuildDirectory}" --target install ${BuildArguments}
          OUT_COMMAND StepCommand
          ERROR_CONTEXT "Build failed: "
        )
        configure_file(
          "${StepScriptFilePath}"
          "${BuildScriptFilePath}"
          FILE_PERMISSIONS OWNER_READ OWNER_WRITE OWNER_EXECUTE GROUP_READ GROUP_WRITE GROUP_EXECUTE WORLD_READ
        )
      endif()
    endif()

    # Read the dependency's package manifest and find its dependencies. Finding these packages here ensures that if the
    # dependency includes them in its link interface, they'll be loaded in the calling project when it needs to actually
    # link with this dependency.
    set(DependencyManifestFilePath "${BuildDirectory}/${ManifestFile}")
    if(EXISTS "${DependencyManifestFilePath}")
      file(STRINGS "${DependencyManifestFilePath}" DependencyPackages)
      foreach(DependencyPackage ${DependencyPackages})
        string(REGEX REPLACE "/Package$" "" PackageName "${DependencyPackage}")
        cmake_path(GET PackageName FILENAME PackageName)

        # Use the current set of package paths when finding the dependency; this is necessary to ensure that the any
        # dependencies of the dependency that use direct find_package() calls that were satisfied by an earlier call to
        # fetch_dependency() will find those dependencies.
        _fd_find(${PackageName} ROOT ${DependencyPackage} PATHS ${DependencyPackages} ${FETCH_DEPENDENCY_PACKAGES})
      endforeach()
    endif()

    # Write the options file now that we know it has succeeded in configuring.
    file(WRITE ${OptionsFilePath} "${RequiredOptions}\n")
    # Write the most up-to-date package manifest so that anything downstream of the calling project will know where its
    # dependencies were written to.
    string(REPLACE ";" "\n" ManifestContent "${FETCH_DEPENDENCY_PACKAGES}")
    file(WRITE ${ManifestFilePath} "${ManifestContent}\n")

    _fd_find(${FD_PACKAGE_NAME} ROOT ${PackageDirectory} PATHS ${DependencyPackages} ${FETCH_DEPENDENCY_PACKAGES})

    # Propagate the updated package directory list.
    set(FETCH_DEPENDENCY_PACKAGES "${FETCH_DEPENDENCY_PACKAGES}" PARENT_SCOPE)
  endif()

  # The dependency was fully-processed, so stamp it with the current FetchDependency version.
  file(WRITE ${VersionFilePath} "${FetchDependencyVersion}")

  message(STATUS "Checking dependency ${FD_NAME} - done")
endfunction()

