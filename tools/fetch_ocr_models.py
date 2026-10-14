"""按固定校验和下载 iOS 所需权重；不下载测试图片，不依赖 Paddle/PyYAML。"""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import urllib.request


def main():
    root = Path(__file__).resolve().parents[1] / 'ios' / 'Runner' / 'OCRModels'
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    if manifest['formatVersion'] != 2:
        raise ValueError('不支持的模型清单版本')
    for model in manifest['models']:
        files = model['files']
        if not files or len(set(files)) != len(files):
            raise ValueError('模型文件清单为空或存在重复项')
        if set(files) != set(model['fileURLs']) or set(files) != set(model['fileSHA256']):
            raise ValueError('模型文件、下载地址与校验和清单不一致')
        for filename in files:
            if filename != Path(filename).name or filename in ('.', '..'):
                raise ValueError(f'非法模型文件名：{filename}')
            if not model['fileURLs'][filename].startswith('https://huggingface.co/PaddlePaddle/'):
                raise ValueError(f'非官方模型下载地址：{model["fileURLs"][filename]}')
        destination = root / model['model'] / model['role']
        config_file = destination / 'config.json'
        # Git 可在 Windows 检出 CRLF；只统一换行，仍严格检查内容、字典及字典顺序。
        config_bytes = config_file.read_bytes().replace(b'\r\n', b'\n')
        if hashlib.sha256(config_bytes).hexdigest() != model['configSHA256']:
            raise ValueError(f'模型配置损坏：{config_file}')
        config = json.loads(config_bytes.decode('utf-8'))
        if config['Global']['model_name'] != f'PP-OCRv6_{model["model"]}_{model["role"]}':
            raise ValueError('模型与固定配置不匹配')
        if all((destination / filename).is_file() for filename in model['files']):
            for filename in model['files']:
                if hashlib.sha256((destination / filename).read_bytes()).hexdigest() != model['fileSHA256'][filename]:
                    raise ValueError(f'本地模型损坏：{destination / filename}')
            print(f'已校验 {model["model"]}/{model["role"]}', flush=True)
            continue
        destination.mkdir(parents=True, exist_ok=True)
        # 暂存目录位于目标磁盘，全部校验通过后原子替换各文件。
        with tempfile.TemporaryDirectory(dir=destination, prefix='.model-') as work:
            for filename in files:
                pending = Path(work) / filename
                print(f'下载 {model["model"]}/{model["role"]}/{filename}', flush=True)
                urllib.request.urlretrieve(model['fileURLs'][filename], pending)
                if hashlib.sha256(pending.read_bytes()).hexdigest() != model['fileSHA256'][filename]:
                    raise ValueError(f'模型文件校验失败：{filename}')
            for filename in files:
                os.replace(Path(work) / filename, destination / filename)


if __name__ == '__main__':
    main()
