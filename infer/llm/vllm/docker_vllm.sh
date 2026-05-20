CONTAINER_NAME='biren_vllm_2604rc'
IMAGE_NAME='birensupa-smartinfer-vllm:26.05.14-py310-pt2.8.0-br1xx'

docker run -it --name $CONTAINER_NAME \
        --cap-add=IPC_LOCK \
        --shm-size='256g' \
        --ulimit memlock=-1 \
        --ulimit nofile=1048576 \
        -v /home:/home \
        -v /data:/data \
        --net host \
        --device /dev/biren \
        $IMAGE_NAME /bin/bash

docker start $CONTAINER_NAME
docker exec -it $CONTAINER_NAME bash
