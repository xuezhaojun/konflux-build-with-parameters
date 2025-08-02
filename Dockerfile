
# Minimal Dockerfile to make repository buildable for Konflux
# This is a basic container that does nothing but allows build processes to complete

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest

# Copy pipeline files to demonstrate this is a pipeline catalog
COPY pipelines/ /pipelines/
COPY .tekton/ /.tekton/

# Use existing user from base image (no network dependencies)
USER 1001

# Set working directory
WORKDIR /pipelines

# Default command that does nothing but keeps container running if needed
CMD ["sleep", "infinity"]