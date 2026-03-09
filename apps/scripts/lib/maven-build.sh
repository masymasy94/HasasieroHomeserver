#!/usr/bin/env bash
# Maven build helper — builds all services in dependency order
#
# Usage: source this file, then call maven_build <project-root>
# Requires: mvn in PATH (provided by workflow's actions/setup-java + Maven setup)

# Build order — update this to match your project's inter-service dependencies
MAVEN_BUILD_ORDER=(
    "common"
    "notification-service"
    "user-service"
    "auth-service"
    "compendium-service"
    "character-service"
    "campaign-service"
    "combat-service"
    "asset-service"
    "chat-service"
    "search-service"
)

maven_build() {
    local project_root="$1"
    local services_dir="${project_root}/services"

    if [[ ! -d "$services_dir" ]]; then
        fatal "Services directory not found: ${services_dir}"
    fi

    if ! command -v mvn &>/dev/null; then
        warn "Maven not found in PATH — skipping build step."
        warn "Ensure artifacts are pre-built, or update the workflow to install JDK + Maven."
        return 0
    fi

    info "Java: $(java -version 2>&1 | head -1)"
    info "Maven: $(mvn --version 2>&1 | head -1)"

    # Build common first
    if [[ -d "${services_dir}/common" ]] && [[ -f "${services_dir}/common/pom.xml" ]]; then
        info "Building common module..."
        mvn -f "${services_dir}/common/pom.xml" clean install -DskipTests -q
        success "common built"
    else
        fatal "Common module not found at ${services_dir}/common"
    fi

    # Build each service in order
    for service in "${MAVEN_BUILD_ORDER[@]}"; do
        [[ "$service" == "common" ]] && continue  # already built above
        local svc_dir="${services_dir}/${service}"
        if [[ -d "$svc_dir" ]] && [[ -f "${svc_dir}/pom.xml" ]]; then
            info "Building ${service}..."
            mvn -f "${svc_dir}/pom.xml" clean install -DskipTests -q
            success "${service} built"
        else
            warn "Skipping ${service} — not found"
        fi
    done

    success "Maven build complete"
}
