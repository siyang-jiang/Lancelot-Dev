import warnings
warnings.filterwarnings('ignore')

import torch
from torch.utils.tensorboard import SummaryWriter
from torchvision.models import resnet18,resnet34,resnet50, mobilenet_v2
import time
import copy
import numpy as np
import random
from tqdm import trange

from utils.options import args_parser
from utils.sampling import noniid
from utils.dataset import load_data, LeNet5
from utils.test import test_img
from utils.byzantine_fl import GPU_krum, krum, trimmed_mean, fang, dummy_contrastive_aggregation
from utils.openfhe import  set_parameters
from utils.attack import compromised_clients, untargeted_attack
from src.aggregation import fedavg,fedavg_5wei
from src.update import BenignUpdate, CompromisedUpdate

import os

def set_seed(seed=42):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    torch.cuda.manual_seed(seed)
    torch.cuda.manual_seed_all(seed)  
    torch.backends.cudnn.deterministic = True
    torch.backends.cudnn.benchmark = False
    os.environ["PYTHONHASHSEED"] = str(seed)

def reshape_flat_list_to_state_dict(flat_list, state_dict_template):
    new_state_dict = {}
    index = 0
    for key, value in state_dict_template.items():
        numel = value.numel()
        new_state_dict[key] = torch.tensor(flat_list[index:index+numel], dtype=value.dtype, device=value.device).reshape(value.shape)
        index += numel
    return new_state_dict


def flatten_dict(d, parent_key='', sep='.'):
    items = []
    for k, v in d.items():
        new_key = f"{parent_key}{sep}{k}" if parent_key else k
        if isinstance(v, dict):
            items.extend(flatten_dict(v, new_key, sep=sep).items())
        else:
            items.append((new_key, v))
    return dict(items)


if __name__ == '__main__':

    # parse args
    args = args_parser()
    args.device = torch.device('cuda:{}'.format(args.gpu) if torch.cuda.is_available() and args.gpu != -1 else 'cpu')

    # args.dataset = "CIFAR10"
    if args.dataset in ["CIFAR10", "MNIST", "FaMNIST","SVHN"]:
    # Change the package  [/home/syjiang/anaconda3/lib/python3.11/site-packages/torchvision/models/resnet.py] Line 197 3 ==> 1 in MNIST and FaMNIST
        args.num_classes = 10
        print("args.num_classes",args.num_classes)

    args.tsboard=True
    if args.tsboard:
        writer = SummaryWriter(f'runs/data')

    set_seed(args.seed)

    dataset_train, dataset_test, dataset_val = load_data(args)

    cnt = 0
    check_acc = 0

    # sample users
    dict_users = noniid(dataset_train, args)


    if args.dataset in ["MNIST","pathmnist","pneumoniamnist","tissuemnist"] :
        net_glob = LeNet5().to(args.device)  #change model
    elif args.dataset in ["FaMNIST","chestmnist","dermamnist","retinamnist","organamnist"]:
        net_glob = resnet18(num_classes = args.num_classes).to(args.device)  #change model
    elif args.dataset in ["CIFAR10","dermamnist","breastmnist","organcmnist"]:
        net_glob = resnet34(num_classes = args.num_classes).to(args.device)  #change model
    elif args.dataset in ["SVHN","octmnist","bloodmnist","organsmnist"]:
        net_glob = resnet50(num_classes = args.num_classes).to(args.device)  #change model
    elif args.dataset in ["ImageNet"]:
        net_glob = mobilenet_v2(num_classes = args.num_classes).to(args.device)  #change model


    net_glob.train()
    w_glob = net_glob.state_dict()

    if args.c_frac > 0:
        compromised_idxs = compromised_clients(args)
    else:
        compromised_idxs = []

    local_traintime=0

    if args.cipher_open:
        file_name = f'log_ciper_{args.dataset}_{args.seed}.txt'
    else:
        file_name = f'log_{args.dataset}_{args.seed}.txt'

    if args.method == 'krum':
        print("We test the krum method, first in plaintext and then in cipertext.")     
    else:
        exit('Error: unrecognized aggregation technique')

    cryptocontext, keypair = set_parameters()

    for iter in trange(args.global_ep):
        w_locals = []
        selected_clients = max(int(args.frac * args.num_clients), 1)
        compromised_num = int(args.c_frac * selected_clients)
        idxs_users = np.random.choice(range(args.num_clients), selected_clients, replace=False)

        for idx in idxs_users:
            if idx in compromised_idxs:
                if args.p == "untarget":
                    w_locals.append(copy.deepcopy(untargeted_attack(net_glob.state_dict(), args)))
                else:
                    local = CompromisedUpdate(args = args, dataset = dataset_train, idxs = dict_users[idx])
                    w = local.train(net = copy.deepcopy(net_glob).to(args.device))
                    w_locals.append(copy.deepcopy(w))

            else:
                local = BenignUpdate(args = args, dataset = dataset_train, idxs = dict_users[idx])
                starttime = time.time()
                w = local.train(net = copy.deepcopy(net_glob).to(args.device))
                endtime = time.time()
                local_traintime+=endtime-starttime

                w_locals.append(copy.deepcopy(w))

        #print("\n+------------------------------------------------+")
        #print("+------------ Train on the plaintext. -----------+") 
        w_glob1, _, round_time = krum(w_locals, compromised_num, args, cryptocontext, keypair)
        if args.openfhe:
            print(f"\n ==> One Round OpenFHE Time is {round_time:.6} Second.")
        else:
            print(f"\n ==> Local Traning Krum Time is {round_time:.6} Second.")
        #print("+-------- End on training the plaintext. --------+") 
        #print("+------------------------------------------------+")
        if args.cipher_open:
            print("\n +------ Train on the ciphertext (Lancelot). -------+") 

            start = time.time()
            w_glob_flat = GPU_krum(w_locals, compromised_num, args)
            end = time.time()
            print(f"==> One Round Lancelot Time is {end-start:.6} Second.")
            w_glob_reshaped = reshape_flat_list_to_state_dict(w_glob_flat, w_glob1)

            flattened_dict_plain, flatten_dict_cipher = flatten_dict(w_glob1), flatten_dict(w_glob_reshaped)

            model_list_w_glob1 = list(flattened_dict_plain.values())
            model_list_w_glob2 = list(flatten_dict_cipher.values())
            
            error = 0
            tmp = 1
            
            # Compare the error
            for x , y in zip(model_list_w_glob1, model_list_w_glob2):
                shape_list = list(x.shape)
                for item in shape_list:
                    tmp *= item 
                x_tmp = x.cpu().detach().numpy()
                y_tmp = y.cpu().detach().numpy()
                error_tmp = torch.norm(x.float()-y.float()).to(torch.float64)
                tmp = float(tmp)
                error += (error_tmp / (tmp))

            # Devide by the number of elements in the model
            error = error / len(model_list_w_glob1)
            if args.checks:
                print(f"Check the error the model between the two methods: {error}", flush=True)  
            #print("+--------- End on the ciphertext --------------+")

            
        if args.cipher_open:
            net_glob.load_state_dict(w_glob_reshaped)
        else:
            net_glob.load_state_dict(w_glob1)

        test_acc, test_loss = test_img(net_glob.to(args.device), dataset_test, args)


        with open(file_name, "a") as log_file: 
            log_message =  f"==> EP: {iter}, Test acc: {test_acc:.4}"
            log_file.write(log_message + "\n") 

        print(f"==> EP: {iter}, Test acc: {test_acc:.4}")
        if check_acc == 0:
            check_acc = test_acc
        elif test_acc < check_acc + args.delta:
            cnt += 1
        else:
            check_acc = test_acc
            cnt = 0

        # early stopping
        if cnt == args.patience:
            print('Early stopped federated training!')
            break

        # tensorboard
        if args.tsboard:
            writer.add_scalar(f'testacc/{args.method}_{args.p}_cfrac_{args.c_frac}_alpha_{args.alpha}', test_acc, iter)
            writer.add_scalar(f'testloss/{args.method}_{args.p}_cfrac_{args.c_frac}_alpha_{args.alpha}', test_loss, iter)

    if args.tsboard:
        writer.close()