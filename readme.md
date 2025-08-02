Proposal: Reinstating CI_VERSION in Konflux Build Pipeline
Status: Proposal
Date: July 15, 2025
Jira: https://issues.redhat.com/browse/ACM-21814
1. Abstract
This document proposes a solution to re-introduce the CI_VERSION environment variable into our container image build process following the migration from the CPass build system to Konflux.
The CI_VERSION variable, which includes the full version string with the patch number (e.g., v2.8.3), is critical for application runtime identification and release artifact tracking. The proposed solution involves integrating a new, read-only Tekton Task into our standard build pipeline. This task will fetch the version from a centrally managed Kubernetes ConfigMap, ensuring a clear separation of concerns between build automation and release management.
2. Background & Problem Statement
In our legacy CPass build system, a CI_VERSION environment variable was automatically generated and injected into the build environment. This variable contained the full, unique version of the artifact being built, including the major, minor, and patch (or "z-stream") numbers.
After migrating to the Konflux, this mechanism for generating the patch version and injecting the full CI_VERSION is no longer present. Our current pipeline builds from a source revision but lacks the context of the release-specific patch number. This proposal aims to restore this critical functionality in a secure, scalable, and maintainable way within the Konflux ecosystem.
3. Proposed Solution
The solution is comprised of three main components: a Kubernetes ConfigMap for state management, a new Tekton Task for logic, and an update to our existing build pipeline to integrate them.
3.1. Component 1: Version State ConfigMap
We will create a Kubernetes ConfigMap named release-versions to act as the single source of truth for the current patch version of each active release branch. The Release Team will be the owner of this ConfigMap.
Workflow: Before initiating a new build for a release, the Release Manager will update the corresponding key-value pair in this ConfigMap to the target patch version.
Example: release-versions-configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: release-versions
  namespace: acm-ci # Or your target namespace
data:
  # Key: Major Version
  # Value: Current Patch Version to be built
  v2.8: "10"
  v2.9: "1"   # The next build for v2.9 will be v2.9.1
  v2.10: "0"


3.2. Component 2: The acm-versioner Tekton Task
A new, read-only Tekton Task named acm-versioner will be created. Its sole responsibility is to read the release-versions ConfigMap and construct the full version string.
Functionality:
Input (major-version param): Takes a major version string (e.g., v2.9).
Logic:
Queries the Kubernetes API to get the release-versions ConfigMap.
Looks up the value associated with the major-version key.
Constructs the full version string (e.g., v2.9.3).
If the key is not found, the task fails, preventing builds with incorrect versions.
Output (full-version result): Emits the complete version string for use by subsequent tasks.
Definition: acm-versioner-task.yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: acm-versioner
spec:
  description: >-
    Reads a patch version from the 'release-versions' ConfigMap and
    constructs the full version string. This task is read-only.
  params:
    - name: major-version
      type: string
  results:
    - name: full-version
      description: "The constructed full version string, e.g., v2.9.3"
  steps:
    - name: get-version-from-configmap
      image: bitnami/kubectl:latest
      script: |
        #!/bin/sh
        set -e
        CONFIG_MAP_NAME="release-versions"
        MAJOR_VERSION="$(params.major-version)"
        PATCH_VERSION=$(kubectl get configmap $CONFIG_MAP_NAME -o "jsonpath={.data['$MAJOR_VERSION']}")
        if [ -z "$PATCH_VERSION" ]; then
          echo "Error: Version for '$MAJOR_VERSION' not found in ConfigMap '$CONFIG_MAP_NAME'."
          exit 1
        fi
        FULL_VERSION="${MAJOR_VERSION}.${PATCH_VERSION}"
        echo -n "$FULL_VERSION" > $(results.full-version.path)


3.3. Component 3: Pipeline Integration
The acm-versioner task will be integrated into the PipelineRun:
Add Pipeline Parameter: A new major-version parameter will be added to the pipeline spec.
Insert Task: A new task entry, get-release-version, will be added. It will run after clone-repository and will call the acm-versioner task.
Inject Build Argument: The build-images task will be modified. The BUILD_ARGS parameter will be updated to include the result from the get-release-version task, formatted as CI_VERSION=$(tasks.get-release-version.results.full-version).
Modified .tekton/xxx-pull-request.yaml (snippet):

https://github.com/stolostron/backplane-operator/blob/d21cb313649367185306a1b3d82c13074fbff977/.tekton/backplane-operator-mce-210-pull-request.yaml#L43
spec:
  params:
    # ... existing params
    - name: major-version
      description: The major version to look up (e.g., v2.9)
      type: string
  tasks:
    # ... init, clone-repository tasks
    - name: get-release-version
      taskRef:
        name: acm-versioner
      runAfter: [clone-repository]
      params:
        - name: major-version
          value: $(params.major-version)
      when: # ... (matches existing when clauses)

    # ... prefetch-dependencies task
    - name: build-images
      runAfter:
        - prefetch-dependencies
        - get-release-version # Add new dependency
      params:
        # ... other params
        - name: BUILD_ARGS
          value:
            - "CI_VERSION=$(tasks.get-release-version.results.full-version)"
            - $(params.build-args[*])
      # ... rest of the task


3.4. Component 4: Dockerfile Modification
Finally, application Dockerfiles must be updated to accept the build argument and set the environment variable.
Example Dockerfile change:
# Accept the build argument from the pipeline
ARG CI_VERSION

# Set the environment variable to make it available at runtime
ENV CI_VERSION=${CI_VERSION}

# The variable is now available for use
RUN echo "Building with version: $CI_VERSION"
