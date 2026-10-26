#!/usr/bin/env bash
set -euo pipefail

log_info() {
    local message="${1}"
    printf '[INFO] %s\n' "${message}"
}

log_error() {
    local message="${1}"
    printf '[ERROR] %s\n' "${message}" >&2
}

print_usage() {
    local script_name="${1}"
    local default_repo="${2}"
    local default_chroot="${3}"
    printf 'Usage: %s [OPTIONS] [PACKAGE...]\n\n' "${script_name}"
    printf 'Options:\n'
    printf '  -r, --repo REPO      COPR repository (default: %s)\n' "${default_repo}"
    printf '  -c, --chroot CHROOT  COPR chroot (default: %s)\n' "${default_chroot}"
    printf '  -f, --force          Build and submit even if version has not changed\n'
    printf '  -n, --dry-run        Update spec files and build SRPMs without submitting to COPR\n'
    printf '  --nowait             Do not wait for COPR build completion\n'
    printf '  -h, --help           Show this help message\n'
}

check_dependencies() {
    local dry_run="${1}"
    local required_cmds=("curl" "git" "jq" "rpmbuild")

    if [[ "${dry_run}" != "true" ]]; then
        required_cmds+=("copr-cli")
    fi

    local cmd
    for cmd in "${required_cmds[@]}"; do
        if ! command -v "${cmd}" >/dev/null 2>&1; then
            log_error "Required command not found: ${cmd}"
            return 1
        fi
    done
    return 0
}

ensure_copr_repo() {
    local copr_repo="${1}"
    local chroot="${2}"
    local project_name="${copr_repo#*/}"

    if copr-cli get-package "${copr_repo}" --name "caprine" >/dev/null 2>&1 || copr-cli list-package-names "${copr_repo}" >/dev/null 2>&1; then
        return 0
    fi

    log_info "Creating COPR repository ${copr_repo} with chroot ${chroot}..."
    copr-cli create "${project_name}" \
        --chroot "${chroot}" \
        --description "Desktop tools and programs repackaged for Fedora"
}

fetch_latest_github_version() {
    local github_repo="${1}"
    local api_url="https://api.github.com/repos/${github_repo}/releases/latest"
    local response

    if ! response="$(curl -fsSL -H "Accept: application/vnd.github+json" "${api_url}")"; then
        log_error "Failed to query GitHub API for ${github_repo}"
        return 1
    fi

    local tag_name
    tag_name="$(jq -r '.tag_name // empty' <<< "${response}")"
    if [[ -z "${tag_name}" ]]; then
        log_error "No tag_name found in latest release for ${github_repo}"
        return 1
    fi

    local version="${tag_name#v}"
    printf '%s\n' "${version}"
}

version_gt() {
    local v1="${1}"
    local v2="${2}"
    local -a a1=() a2=()
    local IFS='.'
    read -r -a a1 <<< "${v1}"
    read -r -a a2 <<< "${v2}"

    local max_len=${#a1[@]}
    if (( ${#a2[@]} > max_len )); then
        max_len=${#a2[@]}
    fi

    local i n1 n2
    for (( i = 0; i < max_len; i++ )); do
        n1="${a1[i]:-0}"
        n2="${a2[i]:-0}"
        if (( 10#${n1} > 10#${n2} )); then
            return 0
        elif (( 10#${n1} < 10#${n2} )); then
            return 1
        fi
    done

    return 1
}

fetch_latest_github_commit() {
    local github_repo="${1}"
    local git_ref="${2:-HEAD}"
    local git_repo_url="https://github.com/${github_repo}.git"
    local query_ref="${git_ref}"
    local output

    if [[ "${query_ref}" != "HEAD" && "${query_ref}" != refs/* ]]; then
        query_ref="refs/heads/${query_ref}"
    fi

    if ! output="$(git ls-remote "${git_repo_url}" "${query_ref}")"; then
        log_error "Failed to query git commit from ${git_repo_url} (${query_ref})"
        return 1
    fi

    local line sha
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        sha="${line%%$'\t'*}"
        sha="${sha%% *}"
        if [[ "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
            printf '%s\n' "${sha}"
            return 0
        fi
    done <<< "${output}"

    log_error "No commit SHA found for ${github_repo} at ${query_ref}"
    return 1
}

fetch_github_raw_file() {
    local github_repo="${1}"
    local commit="${2}"
    local file_path="${3}"
    local url="https://raw.githubusercontent.com/${github_repo}/${commit}/${file_path}"
    local content

    if ! content="$(curl -fsSL "${url}")"; then
        log_error "Failed to fetch ${file_path} from ${github_repo}@${commit}"
        return 1
    fi

    content="${content#"${content%%[![:space:]]*}"}"
    content="${content%"${content##*[![:space:]]}"}"

    if [[ -z "${content}" ]]; then
        log_error "Empty file ${file_path} from ${github_repo}@${commit}"
        return 1
    fi

    printf '%s\n' "${content}"
}

read_spec_global() {
    local spec_file="${1}"
    local global_name="${2}"
    local line

    while IFS= read -r line; do
        if [[ "${line}" =~ ^%global[[:space:]]+([A-Za-z0-9_]+)[[:space:]]+(.*)$ ]]; then
            if [[ "${BASH_REMATCH[1]}" == "${global_name}" ]]; then
                printf '%s\n' "${BASH_REMATCH[2]}"
                return 0
            fi
        fi
    done < "${spec_file}"

    return 1
}

fetch_latest_git_tag_version() {
    local git_repo_url="${1}"
    local output

    if ! output="$(git ls-remote --tags --refs "${git_repo_url}")"; then
        log_error "Failed to query git tags from ${git_repo_url}"
        return 1
    fi

    local latest_version=""
    local line ref tag version
    while IFS= read -r line; do
        ref="${line#*refs/tags/}"
        [[ "${ref}" == "${line}" ]] && continue
        tag="${ref#v}"
        if [[ "${tag}" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
            version="${tag}"
            if [[ -z "${latest_version}" ]] || version_gt "${version}" "${latest_version}"; then
                latest_version="${version}"
            fi
        fi
    done <<< "${output}"

    if [[ -z "${latest_version}" ]]; then
        log_error "No numeric version tags found in ${git_repo_url}"
        return 1
    fi

    printf '%s\n' "${latest_version}"
}

read_spec_field() {
    local spec_file="${1}"
    local field_name="${2}"
    local line key value

    while IFS= read -r line; do
        if [[ "${line}" =~ ^([A-Za-z0-9_]+):[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "${key}" == "${field_name}" ]]; then
                printf '%s\n' "${value}"
                return 0
            fi
        fi
    done < "${spec_file}"

    return 1
}

to_rpm_version() {
    local version="${1}"
    local rpm_version="${version//-/\~}"

    if [[ "${rpm_version}" =~ ^([0-9]+(\.[0-9]+)*)\.(alpha[0-9]*|beta[0-9]*|rc[0-9]*)$ ]]; then
        rpm_version="${BASH_REMATCH[1]}~${BASH_REMATCH[3]}"
    fi

    printf '%s\n' "${rpm_version}"
}

read_local_version() {
    local version_file="${1}"
    local version=""

    if [[ ! -f "${version_file}" ]]; then
        log_error "Missing version file: ${version_file}"
        return 1
    fi

    IFS= read -r version < "${version_file}" || true
    version="${version#"${version%%[![:space:]]*}"}"
    version="${version%"${version##*[![:space:]]}"}"

    if [[ -z "${version}" ]]; then
        log_error "Empty version file: ${version_file}"
        return 1
    fi

    printf '%s\n' "${version}"
}

read_spec_sources() {
    local spec_file="${1}"
    local version="${2}"
    local package_name="${3:-}"
    local rpm_version
    rpm_version="$(to_rpm_version "${version}")"
    local commit=""
    commit="$(read_spec_global "${spec_file}" "commit" || true)"
    local line value expanded

    while IFS= read -r line; do
        if [[ "${line}" =~ ^Source[0-9]*:[[:space:]]*(.*)$ ]]; then
            value="${BASH_REMATCH[1]}"
            expanded="${value//%\{upstream_version\}/${version}}"
            expanded="${expanded//%\{version\}/${rpm_version}}"
            if [[ -n "${package_name}" ]]; then
                expanded="${expanded//%\{name\}/${package_name}}"
            fi
            if [[ -n "${commit}" ]]; then
                expanded="${expanded//%\{commit\}/${commit}}"
            fi
            printf '%s\n' "${expanded}"
        fi
    done < "${spec_file}"
}

update_spec_version() {
    local spec_file="${1}"
    local new_version="${2}"
    local new_commit="${3:-}"
    local rpm_version
    rpm_version="$(to_rpm_version "${new_version}")"
    local shortcommit="${new_commit:0:7}"
    local changelog_date
    printf -v changelog_date '%(%a %b %d %Y)T' -1

    local -a updated_lines=()
    local line

    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" =~ ^(%global[[:space:]]+upstream_version[[:space:]]+).*$ ]]; then
            updated_lines+=("${BASH_REMATCH[1]}${new_version}")
        elif [[ "${line}" =~ ^(%global[[:space:]]+commit[[:space:]]+).*$ ]]; then
            if [[ -n "${new_commit}" ]]; then
                updated_lines+=("${BASH_REMATCH[1]}${new_commit}")
            else
                updated_lines+=("${line}")
            fi
        elif [[ "${line}" =~ ^(%global[[:space:]]+shortcommit[[:space:]]+).*$ ]]; then
            if [[ -n "${new_commit}" ]]; then
                updated_lines+=("${BASH_REMATCH[1]}${shortcommit}")
            else
                updated_lines+=("${line}")
            fi
        elif [[ "${line}" =~ ^(Version:[[:space:]]*).*$ ]]; then
            updated_lines+=("${BASH_REMATCH[1]}${rpm_version}")
        elif [[ "${line}" =~ ^(Release:[[:space:]]*).*$ ]]; then
            if [[ -n "${new_commit}" ]]; then
                updated_lines+=("${line}")
            else
                updated_lines+=("${BASH_REMATCH[1]}1%{?dist}")
            fi
        elif [[ "${line}" == "%changelog" ]]; then
            updated_lines+=("${line}")
            if [[ -n "${new_commit}" ]]; then
                updated_lines+=("* ${changelog_date} neir-copr - ${rpm_version}-1.git${shortcommit}")
                updated_lines+=("- Snapshot ${new_version} (${shortcommit})")
            else
                updated_lines+=("* ${changelog_date} neir-copr - ${rpm_version}-1")
                updated_lines+=("- Repackage upstream release ${new_version}")
            fi
            updated_lines+=("")
        else
            updated_lines+=("${line}")
        fi
    done < "${spec_file}"

    printf '%s\n' "${updated_lines[@]}" > "${spec_file}"
}

download_sources() {
    local spec_file="${1}"
    local version="${2}"
    local sources_dir="${3}"
    local package_name="${4:-}"

    mkdir -p "${sources_dir}"

    local -a source_urls=()
    mapfile -t source_urls < <(read_spec_sources "${spec_file}" "${version}" "${package_name}")

    local url filename dest_path
    for url in "${source_urls[@]}"; do
        [[ -z "${url}" ]] && continue
        filename="${url##*/}"
        dest_path="${sources_dir}/${filename}"
        if [[ -f "${dest_path}" ]]; then
            log_info "Using cached source: ${filename}"
        else
            log_info "Downloading ${url}..."
            curl -fL --retry 3 -o "${dest_path}.part" "${url}"
            mv "${dest_path}.part" "${dest_path}"
        fi
    done
}

stage_local_source_tarball() {
    local pkg_dir="${1}"
    local package_name="${2}"
    local rpm_version="${3}"
    local sources_dir="${4}"
    local tarball="${package_name}-${rpm_version}.tar.gz"
    local dest_path="${sources_dir}/${tarball}"
    local stage root

    if [[ ! -d "${pkg_dir}/nier/bin" || ! -d "${pkg_dir}/nier/share" ]]; then
        log_error "Local source tree missing nier/bin or nier/share in ${pkg_dir}"
        return 1
    fi

    mkdir -p "${sources_dir}"
    stage="$(mktemp -d)"
    root="${stage}/${package_name}-${rpm_version}"
    mkdir -p "${root}/nier"
    cp -a "${pkg_dir}/nier/bin" "${root}/nier/bin"
    cp -a "${pkg_dir}/nier/share" "${root}/nier/share"
    tar -C "${stage}" -czf "${dest_path}" "${package_name}-${rpm_version}"
    rm -rf "${stage}"
    log_info "Staged local source tarball: ${tarball}"
}

build_srpm() {
    local spec_file="${1}"
    local work_dir="${2}"
    local sources_dir="${work_dir}/SOURCES"
    local srpm_dir="${work_dir}/SRPMS"

    mkdir -p "${sources_dir}" "${srpm_dir}"

    rpmbuild -bs \
        --define "_topdir ${work_dir}" \
        --define "_sourcedir ${sources_dir}" \
        --define "_srcrpmdir ${srpm_dir}" \
        --define "_specdir ${spec_file%/*}" \
        "${spec_file}" >&2

    local -a srpms=("${srpm_dir}"/*.src.rpm)
    if [[ ! -e "${srpms[0]}" ]]; then
        log_error "Failed to locate generated SRPM in ${srpm_dir}"
        return 1
    fi

    printf '%s\n' "${srpms[0]}"
}

submit_to_copr() {
    local copr_repo="${1}"
    local chroot="${2}"
    local srpm_path="${3}"
    local nowait="${4}"
    local -a build_args=("build" "-r" "${chroot}")

    if [[ "${nowait}" == "true" ]]; then
        build_args+=("--nowait")
    fi

    build_args+=("${copr_repo}" "${srpm_path}")

    log_info "Submitting ${srpm_path##*/} to COPR (${copr_repo}, ${chroot})..."
    copr-cli "${build_args[@]}"
}

process_package() {
    local pkg_dir="${1}"
    local build_root="${2}"
    local state_dir="${3}"
    local copr_repo="${4}"
    local chroot="${5}"
    local force_build="${6}"
    local dry_run="${7}"
    local nowait="${8}"

    local conf_file="${pkg_dir}/package.conf"
    if [[ ! -f "${conf_file}" ]]; then
        log_error "Missing package.conf in ${pkg_dir}"
        return 1
    fi

    local GITHUB_REPO=""
    local GIT_TAG_REPO=""
    local GITHUB_COMMIT_REPO=""
    local GIT_REF="main"
    local PACKAGE_NAME=""
    local LOCAL_SOURCE=""
    local VERSION_FILE=""
    source "${conf_file}"

    if [[ "${LOCAL_SOURCE}" == "1" || "${LOCAL_SOURCE}" == "true" ]]; then
        LOCAL_SOURCE="1"
    else
        LOCAL_SOURCE="0"
    fi

    if [[ -z "${PACKAGE_NAME}" || ( "${LOCAL_SOURCE}" != "1" && -z "${GITHUB_REPO}" && -z "${GIT_TAG_REPO}" && -z "${GITHUB_COMMIT_REPO}" ) ]]; then
        log_error "Invalid package.conf in ${pkg_dir}: PACKAGE_NAME and either LOCAL_SOURCE, GITHUB_REPO, GIT_TAG_REPO, or GITHUB_COMMIT_REPO are required"
        return 1
    fi

    local spec_file="${pkg_dir}/${PACKAGE_NAME}.spec"
    if [[ ! -f "${spec_file}" ]]; then
        log_error "Missing spec file: ${spec_file}"
        return 1
    fi

    local latest_version=""
    local latest_commit=""
    if [[ "${LOCAL_SOURCE}" == "1" ]]; then
        if [[ -z "${VERSION_FILE}" ]]; then
            log_error "Invalid package.conf in ${pkg_dir}: VERSION_FILE is required when LOCAL_SOURCE=1"
            return 1
        fi
        latest_version="$(read_local_version "${pkg_dir}/${VERSION_FILE}")"
        log_info "Checking ${PACKAGE_NAME} (local source ${latest_version})..."
    elif [[ -n "${GITHUB_COMMIT_REPO}" ]]; then
        latest_commit="$(fetch_latest_github_commit "${GITHUB_COMMIT_REPO}" "${GIT_REF}")"
        if [[ -n "${VERSION_FILE}" ]]; then
            latest_version="$(fetch_github_raw_file "${GITHUB_COMMIT_REPO}" "${latest_commit}" "${VERSION_FILE}")"
        else
            latest_version="$(read_spec_field "${spec_file}" "Version")"
        fi
        log_info "Checking ${PACKAGE_NAME} (${GITHUB_COMMIT_REPO}@${latest_commit:0:7}, ${latest_version})..."
    elif [[ -n "${GITHUB_REPO}" ]]; then
        log_info "Checking ${PACKAGE_NAME} (${GITHUB_REPO})..."
        latest_version="$(fetch_latest_github_version "${GITHUB_REPO}")"
    else
        log_info "Checking ${PACKAGE_NAME} (${GIT_TAG_REPO})..."
        latest_version="$(fetch_latest_git_tag_version "${GIT_TAG_REPO}")"
    fi

    local spec_version
    spec_version="$(read_spec_field "${spec_file}" "Version")"
    local spec_commit=""
    spec_commit="$(read_spec_global "${spec_file}" "commit" || true)"
    local expected_rpm_version
    expected_rpm_version="$(to_rpm_version "${latest_version}")"

    local state_file="${state_dir}/${PACKAGE_NAME}.version"
    local published_version=""
    if [[ -f "${state_file}" ]]; then
        IFS= read -r published_version < "${state_file}" || true
    fi

    local track_id="${latest_version}"
    if [[ -n "${latest_commit}" ]]; then
        track_id="${latest_commit}"
    fi

    local needs_spec_update="false"
    if [[ "${spec_version}" != "${expected_rpm_version}" ]]; then
        needs_spec_update="true"
    fi
    if [[ -n "${latest_commit}" && "${spec_commit}" != "${latest_commit}" ]]; then
        needs_spec_update="true"
    fi

    if [[ "${needs_spec_update}" == "true" ]]; then
        if [[ -n "${latest_commit}" ]]; then
            log_info "Updating ${PACKAGE_NAME} spec to ${expected_rpm_version} (${latest_commit:0:7})"
        else
            log_info "Updating ${PACKAGE_NAME} spec from ${spec_version} to ${expected_rpm_version}"
        fi
        update_spec_version "${spec_file}" "${latest_version}" "${latest_commit}"
    fi

    if [[ "${force_build}" != "true" && "${published_version}" == "${track_id}" ]]; then
        log_info "${PACKAGE_NAME} ${track_id} is already published to ${copr_repo}; skipping."
        return 0
    fi

    local pkg_work_dir="${build_root}/${PACKAGE_NAME}-${track_id}"
    rm -rf "${pkg_work_dir}"
    mkdir -p "${pkg_work_dir}"

    if [[ "${LOCAL_SOURCE}" == "1" ]]; then
        stage_local_source_tarball "${pkg_dir}" "${PACKAGE_NAME}" "${expected_rpm_version}" "${pkg_work_dir}/SOURCES"
    else
        download_sources "${spec_file}" "${latest_version}" "${pkg_work_dir}/SOURCES" "${PACKAGE_NAME}"
    fi

    log_info "Building SRPM for ${PACKAGE_NAME} ${latest_version}..."
    local srpm_path
    srpm_path="$(build_srpm "${spec_file}" "${pkg_work_dir}")"
    log_info "Built SRPM: ${srpm_path}"

    if [[ "${dry_run}" == "true" ]]; then
        log_info "Dry-run enabled; skipping COPR upload for ${PACKAGE_NAME} ${latest_version}."
        return 0
    fi

    ensure_copr_repo "${copr_repo}" "${chroot}"
    submit_to_copr "${copr_repo}" "${chroot}" "${srpm_path}" "${nowait}"

    mkdir -p "${state_dir}"
    printf '%s\n' "${track_id}" > "${state_file}"
    log_info "Recorded ${PACKAGE_NAME} ${track_id} as published."
}

main() {
    local script_path="${BASH_SOURCE[0]}"
    local script_dir
    script_dir="$(cd -- "${script_path%/*}" && pwd)"

    local copr_repo="${COPR_REPO:-byte0/nier}"
    local chroot="${COPR_CHROOT:-fedora-44-x86_64}"
    local force_build="false"
    local dry_run="false"
    local nowait="false"
    local -a requested_packages=()

    while [[ $# -gt 0 ]]; do
        case "${1}" in
            -r|--repo)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing argument for ${1}"
                    return 1
                fi
                copr_repo="${2}"
                shift 2
                ;;
            -c|--chroot)
                if [[ $# -lt 2 ]]; then
                    log_error "Missing argument for ${1}"
                    return 1
                fi
                chroot="${2}"
                shift 2
                ;;
            -f|--force)
                force_build="true"
                shift
                ;;
            -n|--dry-run)
                dry_run="true"
                shift
                ;;
            --nowait)
                nowait="true"
                shift
                ;;
            -h|--help)
                print_usage "${script_path##*/}" "${copr_repo}" "${chroot}"
                return 0
                ;;
            -*)
                log_error "Unknown option: ${1}"
                print_usage "${script_path##*/}" "${copr_repo}" "${chroot}"
                return 1
                ;;
            *)
                requested_packages+=("${1}")
                shift
                ;;
        esac
    done

    check_dependencies "${dry_run}"

    local packages_root="${script_dir}/packages"
    local build_root="${script_dir}/.build"
    local state_dir="${script_dir}/.state"

    local -a package_dirs=()
    if [[ ${#requested_packages[@]} -gt 0 ]]; then
        local pkg
        for pkg in "${requested_packages[@]}"; do
            if [[ ! -d "${packages_root}/${pkg}" ]]; then
                log_error "Unknown package: ${pkg}"
                return 1
            fi
            package_dirs+=("${packages_root}/${pkg}")
        done
    else
        local dir
        for dir in "${packages_root}"/*; do
            [[ -d "${dir}" ]] && package_dirs+=("${dir}")
        done
    fi

    if [[ ${#package_dirs[@]} -eq 0 ]]; then
        log_error "No packages found in ${packages_root}"
        return 1
    fi

    local pkg_dir
    for pkg_dir in "${package_dirs[@]}"; do
        process_package \
            "${pkg_dir}" \
            "${build_root}" \
            "${state_dir}" \
            "${copr_repo}" \
            "${chroot}" \
            "${force_build}" \
            "${dry_run}" \
            "${nowait}"
    done
}

main "$@"
