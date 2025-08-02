
# Minimal Dockerfile to make repository buildable for Konflux
# This is a basic container that does nothing but allows build processes to complete

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Accept the build argument from the pipeline
ARG CI_VERSION

# Set the environment variable to make it available at runtime
ENV CI_VERSION=${CI_VERSION}

# The variable is now available for use
RUN echo "Building with version: $CI_VERSION"

# Use existing user from base image (no network dependencies)
USER 1001

# Default command that does nothing but keeps container running if needed
CMD ["sleep", "infinity"]