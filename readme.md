# Konflux Build with Parameters

**Status**: Implemented
**Date**: August 2, 2025
**Jira**: https://issues.redhat.com/browse/ACM-21814

## 1. Abstract

This document describes the implemented solution to re-introduce the CI_VERSION environment variable into our container image build process following the migration from the CPass build system to Konflux.

The CI_VERSION variable, which includes the full version string with the patch number (e.g., v2.10.5), is critical for application runtime identification and release artifact tracking. The implemented solution integrates a new, read-only Tekton Task into our standard build pipeline. This task fetches version information from a centrally managed Kubernetes ConfigMap, ensuring a clear separation of concerns between build automation and release management.

## 2. Background & Problem Statement

In our legacy CPass build system, a CI_VERSION environment variable was automatically generated and injected into the build environment. This variable contained the full, unique version of the artifact being built, including the major, minor, and patch (or "z-stream") numbers.

After migrating to Konflux, this mechanism for generating the patch version and injecting the full CI_VERSION is no longer present. Our current pipeline builds from a source revision but lacks the context of the release-specific patch number. This implementation restores this critical functionality in a secure, scalable, and maintainable way within the Konflux ecosystem.

## 3. Implemented Solution

The solution is comprised of three main components: a Kubernetes ConfigMap for state management, a new Tekton Task for logic, and an update to our existing build pipeline to integrate them.

### 3.1. Component 1: Build Parameters ConfigMap

We have created a Kubernetes ConfigMap named `build-parameters` to act as the single source of truth for version information used in builds. The Release Team is the owner of this ConfigMap.

**Workflow**: Before initiating a new build for a release, the Release Manager updates the corresponding key-value pair in this ConfigMap to the target version.

**Example**: `test-configmap.yaml`
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: build-parameters
  namespace: zxue-tenant
data:
  CI_VERSION_2_10: "2.10.5"
  CI_VERSION_2_9: "2.9.8"
  # Additional build parameters can be added as needed
```


### 3.2. Component 2: The configmap-to-env Tekton Task

A new, read-only Tekton Task named `configmap-to-env` has been created. Its responsibility is to read the `build-parameters` ConfigMap and extract version information for use in builds.

**Functionality**:
- **Input**: `configMapName` parameter specifying which ConfigMap to read from
- **Logic**:
  - Queries the Kubernetes API to get the specified ConfigMap
  - Extracts predefined keys (`CI_VERSION_2_10`, `CI_VERSION_2_9`)
  - Provides individual results for each version
- **Output**: Separate results for each version, allowing downstream tasks to choose which version to use

**Definition**: `.tekton/configmap-to-env.yaml`
```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: configmap-to-env
  labels:
    app.kubernetes.io/version: "0.1"
  annotations:
    tekton.dev/pipelines.minVersion: "0.12.1"
    tekton.dev/tags: "utility, configmap, environment"
spec:
  description: >-
    This task reads specified keys from a Kubernetes ConfigMap
    and outputs them as task results in KEY=VALUE format.
    This allows subsequent tasks to easily use these values as environment variables.

  params:
    - name: configMapName
      type: string
      description: The name of the ConfigMap to read from.

  results:
    - name: CI_VERSION_2_10
      description: The CI_VERSION value from the ConfigMap.

    - name: CI_VERSION_2_9
      description: The CI_VERSION value from the ConfigMap.

  steps:
    - name: extract-from-configmap
      image: bitnami/kubectl:latest
      script: |
        #!/bin/sh
        set -e
        # Script extracts values and writes them to result files
        # See full implementation in .tekton/configmap-to-env.yaml
```


### 3.3. Component 3: Pipeline Integration

The `configmap-to-env` task has been integrated into the PipelineRun:

1. **Insert Task**: A new task entry, `configmap-to-env`, has been added. It runs after `clone-repository` and calls the `configmap-to-env` task.
2. **Update Dependencies**: The `prefetch-dependencies` task now depends on `configmap-to-env`.
3. **Inject Build Argument**: The `build-container` task has been modified. The `BUILD_ARGS` parameter now includes the result from the `configmap-to-env` task, formatted as `CI_VERSION=$(tasks.configmap-to-env.results.CI_VERSION_2_10)`.

**Modified** `.tekton/konflux-build-with-parameters-aa260-pull-request.yaml` **(snippet)**:

```yaml
tasks:
  # ... init, clone-repository tasks
  - name: configmap-to-env
    params:
    - name: configMapName
      value: build-parameters
    runAfter:
    - clone-repository
    taskSpec:
      # Inline task definition for self-contained deployment
      # See full implementation in the pipeline file

  - name: prefetch-dependencies
    # ... other params
    runAfter:
    - configmap-to-env
    # ... rest of task definition

  - name: build-container
    runAfter:
      - prefetch-dependencies
      - configmap-to-env # Add new dependency
    params:
      # ... other params
      - name: BUILD_ARGS
        value:
        - $(params.build-args[*])
        - "CI_VERSION=$(tasks.configmap-to-env.results.CI_VERSION_2_10)"
    # ... rest of the task
```


### 3.4. Component 4: Dockerfile Modification

Application Dockerfiles must be updated to accept the build argument and set the environment variable.

**Example Dockerfile change**:
```dockerfile
# Accept the build argument from the pipeline
ARG CI_VERSION

# Set the environment variable to make it available at runtime
ENV CI_VERSION=${CI_VERSION}

# The variable is now available for use
RUN echo "Building with version: $CI_VERSION"
```
