#! /bin/bash

# Change for multinode config
MP_SIZE=1
TOTAL_BATCHSIZE=512
NUM_WORKERS=4 #${DLTS_NUM_WORKER}
NUM_GPUS_PER_WORKER=16 #${DLTS_NUM_GPU_PER_WORKER}
HIDDEN_SIZE=1024
NUM_ATTN_HEADS=16
NUM_LAYERS=24 # 50
BATCHSIZE=$((MP_SIZE*TOTAL_BATCHSIZE/NUM_WORKERS/NUM_GPUS_PER_WORKER)) # per gpu

###DATA_PATH=/data/megatron-data/indexed/my-gpt2_text_document
###VOCAB_PATH=/data/megatron-data/gpt2-vocab.json
###MERGE_PATH=/data/megatron-data/gpt2-merges.txt

DATA_PATH=/data/Megatron-LM/data/indexed_datasets/megatron
VOCAB_PATH=/data/Megatron-LM/data/gpt2-vocab.json
MERGE_PATH=/data/Megatron-LM/data/gpt2-merges.txt

#ZeRO Configs
stage=2
reduce_scatter=true
contigious_gradients=true
rbs=50000000
agbs=5000000000

script_path=$(realpath $0)
script_dir=$(dirname $script_path)
curriculum=$1
tag=$2
config_json="$script_dir/ds_zero_stage_${stage}_config_curriculum_${curriculum}.json"

#Actication Checkpointing and Contigious Memory
chkp_layers=1
PA=true
PA_CPU=false
CC=true
SYNCHRONIZE=true
PROFILE=false


# Megatron Model Parallelism
current_time=$(date "+%Y.%m.%d-%H.%M.%S")
JOB_NAME="gpt2_345M_curriculum_${curriculum}_${tag}_stage${stage}-lazyscatter-${NUM_LAYERS}l_${HIDDEN_SIZE}h_${NUM_WORKERS}n_${NUM_GPUS_PER_WORKER}g_${MP_SIZE}mp_${BATCHSIZE}b_${current_time}"
LOGDIR="tboard/${JOB_NAME}"
CHECKPOINT_PATH="checkpoints/${JOB_NAME}"

gpt_options=" \
        --model-parallel-size ${MP_SIZE} \
        --num-layers $NUM_LAYERS \
        --hidden-size $HIDDEN_SIZE \
        --num-attention-heads 16 \
        --seq-length 1024 \
        --max-position-embeddings 1024 \
        --batch-size $BATCHSIZE \
        --train-iters 300000 \
        --lr-decay-iters 300000 \
        --save $CHECKPOINT_PATH \
        --load $CHECKPOINT_PATH \
        --data-path $DATA_PATH \
        --vocab-file $VOCAB_PATH \
        --merge-file $MERGE_PATH \
        --data-impl mmap \
        --split 949,50,1 \
        --distributed-backend nccl \
        --lr 1.5e-4 \
        --lr-decay-style cosine \
        --min-lr 1.0e-5 \
        --weight-decay 1e-2 \
        --clip-grad 1.0 \
        --warmup 0.01 \
        --checkpoint-activations \
        --log-interval 100 \
        --save-interval 10000 \
        --eval-interval 1000 \
        --eval-iters 10 \
        --fp16 \
        --tensorboard-dir ${LOGDIR}
"

 deepspeed_options=" \
                --deepspeed \
                --deepspeed_config ${config_json} \
                --zero-stage ${stage} \
                --zero-reduce-bucket-size ${rbs} \
                --zero-allgather-bucket-size ${agbs}
            "

if [ "${contigious_gradients}" = "true" ]; then
deepspeed_options="${deepspeed_options} \
                --zero-contigious-gradients"
fi

if [ "${reduce_scatter}" = "true" ]; then
deepspeed_options="${deepspeed_options} \
                --zero-reduce-scatter"
fi

chkp_opt=" \
--deepspeed-activation-checkpointing \
--checkpoint-num-layers ${chkp_layers}"

if [ "${PA}" = "true" ]; then
chkp_opt="${chkp_opt} --partition-activations"
fi

if [ "${PA_CPU}" = "true" ]; then
chkp_opt="${chkp_opt} \
        --checkpoint-in-cpu"
fi

if [ "${SYNCHRONIZE}" = "true" ]; then
chkp_opt="${chkp_opt} \
        --synchronize-each-layer"
fi

if [ "${CC}" = "true" ]; then
chkp_opt="${chkp_opt} \
        --contigious-checkpointing"
fi

if [ "${PROFILE}" = "true" ]; then
chkp_opt="${chkp_opt} \
        --profile-backward"
fi


full_options="${gpt_options} ${deepspeed_options} ${chkp_opt}"

run_cmd="deepspeed --num_nodes ${NUM_WORKERS} --num_gpus ${NUM_GPUS_PER_WORKER}  pretrain_gpt2.py ${@:2} ${full_options} &> ${JOB_NAME}.log"
echo ${run_cmd}
eval ${run_cmd}

set +x