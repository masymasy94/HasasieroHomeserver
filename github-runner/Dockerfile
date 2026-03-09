FROM myoung34/github-runner:latest

# Install JDK 25 (Eclipse Temurin) and Maven 3.9.9
# These are needed to build Maven projects before Docker compose
# Remove or modify this section if your projects don't use Maven/Java

ARG JDK_VERSION=25
ARG MAVEN_VERSION=3.9.9

# Install JDK via Adoptium APT repository
RUN apt-get update && \
    apt-get install -y --no-install-recommends wget apt-transport-https gpg && \
    wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" \
        > /etc/apt/sources.list.d/adoptium.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends temurin-${JDK_VERSION}-jdk && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install nmcli so deploy scripts can manage host IP aliases via NetworkManager
RUN apt-get update && \
    apt-get install -y --no-install-recommends network-manager iproute2 && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Maven
RUN curl -fsSL "https://archive.apache.org/dist/maven/maven-3/${MAVEN_VERSION}/binaries/apache-maven-${MAVEN_VERSION}-bin.tar.gz" \
        | tar xzf - -C /opt && \
    ln -s /opt/apache-maven-${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn

# Verify
RUN java -version && mvn --version

# Multi-repo entrypoint: discovers all user repos and runs one runner per repo
COPY multi-runner-entrypoint.sh /multi-runner-entrypoint.sh
RUN chmod +x /multi-runner-entrypoint.sh

ENTRYPOINT ["/multi-runner-entrypoint.sh"]
