#!/usr/bin/env bash
# Maven build helper — delegates to Maven reactor via root pom.xml
#
# Usage: source this file, then call maven_build <project-root>
# Requires: mvn in PATH (provided by workflow's actions/setup-java + Maven setup)

maven_build() {
    local project_root="$1"
    local root_pom="${project_root}/pom.xml"

    if ! command -v mvn &>/dev/null; then
        warn "Maven not found in PATH — skipping build step."
        warn "Ensure artifacts are pre-built, or update the workflow to install JDK + Maven."
        return 0
    fi

    info "Java: $(java -version 2>&1 | head -1)"
    info "Maven: $(mvn --version 2>&1 | head -1)"

    if [[ -f "$root_pom" ]]; then
        info "Building all modules via Maven reactor..."
        mvn -f "$root_pom" clean install -DskipTests -q
        success "Maven reactor build complete"
        return 0
    fi

    # Fallback: no root pom.xml — build common + services manually (order not guaranteed)
    warn "No root pom.xml found at ${project_root} — falling back to per-service build"
    local services_dir="${project_root}/services"
    [[ -d "$services_dir" ]] || fatal "Services directory not found: ${services_dir}"
    [[ -f "${services_dir}/common/pom.xml" ]] || fatal "Common module not found at ${services_dir}/common"

    info "Building common module..."
    mvn -f "${services_dir}/common/pom.xml" clean install -DskipTests -q
    success "common built"

    for svc_pom in "${services_dir}"/*/pom.xml; do
        local svc_name
        svc_name="$(basename "$(dirname "$svc_pom")")"
        [[ "$svc_name" == "common" ]] && continue
        info "Building ${svc_name}..."
        mvn -f "$svc_pom" clean install -DskipTests -q
        success "${svc_name} built"
    done

    success "Maven build complete"
}
