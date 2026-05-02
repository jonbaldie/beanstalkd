#!/usr/bin/env sh
set -e

echo "Starting beanstalkd container..."
CONTAINER_ID=$(docker run -d -p 11300:11300 jonbaldie/beanstalkd:latest)

# Ensure the container is destroyed when the script exits
trap "echo 'Tearing down container...'; docker rm -f $CONTAINER_ID > /dev/null" EXIT

# Wait for the service to become available
MAX_RETRIES=30
RETRY_COUNT=0
echo "Waiting for beanstalkd to start on port 11300..."

while ! nc -z localhost 11300; do
    RETRY_COUNT=$((RETRY_COUNT+1))
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        echo "Error: beanstalkd did not start within $MAX_RETRIES seconds."
        echo "Container logs:"
        docker logs $CONTAINER_ID
        exit 1
    fi
    sleep 1
done

echo "Success! beanstalkd is accepting connections on port 11300."
