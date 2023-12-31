export GLOO_SOCKET_IFNAME=eth0
export WANDB_MODE=disabled

maindir=$1
datadir=${maindir}data
codedir=${maindir}code

MAXLEN=2048
EPOCH=3
test_data=${datadir}/data/dummy_conversation.json

settings=("")  # use this for zeroshot or finetuning
models=("t5-3b" "vicuna-7b" "vicuna-13b" "vicuna-33b" "llama2-70b")

for model in "${models[@]}"
    do

    raw_model_path=${maindir}model/fastchat-${model}/
    case ${model} in 
        "llama2-70b")
            RAYGPUS=4
            ;;
        "vicuna-33b")
            RAYGPUS=2
            ;;
        "t5-3b"|"vicuna-7b"|"vicuna-13b")
            RAYGPUS=1
            ;;
    esac
    
    # tuning
    for setting in "${settings[@]}"
        do
        data_path=${datadir}/train_${setting}.json
        preprocessed_data_dir=${datadir}/processed_${setting}_${model%-*}.pt
        model_output_path=${maindir}model/${model}_${setting}/
        deepspeed_config_path=${codedir}/configs/ds_config_${model#*-}.json

        case ${model} in 
            "t5-3b")
                PER_GPU_BATCH=8
                GRA_ACC=2
                ;;
            "vicuna-7b")
                PER_GPU_BATCH=16
                GRA_ACC=1
                ;;
            "vicuna-13b")
                PER_GPU_BATCH=8
                GRA_ACC=2
                ;;
            "vicuna-33b")
                PER_GPU_BATCH=4
                GRA_ACC=4
                ;;
            "llama2-70b")
                PER_GPU_BATCH=4
                GRA_ACC=2
                ;;
        esac

        # train data preprocess
        python3 ${codedir}/codes/train/data_preprocess.py \
            --model_name_or_path ${raw_model_path} \
            --data_path ${data_path} \
            --preprocessing_num_workers=1 \
            --model_max_length ${MAXLEN} \
            --preprocessed_path ${preprocessed_data_dir}
        
        # training: avaliable for multi nodes
        torchrun --nnodes=$NODE_NUM \
            --node_rank=$INDEX \
            --nproc_per_node $GPU_NUM_PER_NODE \
            --master_addr $MASTER_ADDR \
            --master_port $MASTER_PORT \
            ${codedir}/codes/train/train.py \
            --model_name_or_path ${raw_model_path} \
            --bf16 True \
            --output_dir ${model_output_path} \
            --num_train_epochs ${EPOCH} \
            --per_device_train_batch_size ${PER_GPU_BATCH} \
            --gradient_accumulation_steps ${GRA_ACC} \
            --save_strategy "steps" \
            --save_steps 1500 \
            --save_total_limit 1 \
            --learning_rate 2e-5 \
            --log_level "info" \
            --logging_strategy "steps" \
            --logging_steps 1 \
            --weight_decay 0. \
            --warmup_ratio 0.04 \
            --lr_scheduler_type "cosine" \
            --deepspeed ${deepspeed_config_path} \
            --tf32 True \
            --model_max_length ${MAXLEN} \
            --preprocessed_path ${preprocessed_data_dir} \
            --gradient_checkpointing True \
            --report_to "none"
        
        # tuning inference
        # python3 ${codedir}/codes/eval/get_model_infer_simple.py \
        #     --model-id ${model}_${setting} \
        #     --model-path ${model_output_path} \
        #     --question-file ${test_data} \
        #     --answer-file ${datadir}/instruction_testing/instruction_testing_${model}_${setting}.jsonl \
        #     --num-gpus $GPU_NUM_PER_NODE \
        #     --ray-num-gpus ${RAYGPUS}
        done
    done
