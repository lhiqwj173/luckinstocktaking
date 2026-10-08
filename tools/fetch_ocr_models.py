"""按固定校验和下载 iOS 所需权重；不下载测试图片，不依赖 Paddle/PyYAML。"""
import hashlib
import json
import os
from pathlib import Path
import tarfile
import tempfile
import urllib.request


def main():
    root = Path(__file__).resolve().parents[1] / 'ios' / 'Runner' / 'OCRModels'
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    if manifest['formatVersion'] != 1:
        raise ValueError('不支持的模型清单版本')
    for model in manifest['models']:
        destination = root / model['model'] / model['role']
        config_file = destination / 'config.json'
        if hashlib.sha256(config_file.read_bytes()).hexdigest() != model['configSHA256']:
            raise ValueError(f'模型配置损坏：{config_file}')
        config = json.loads(config_file.read_text(encoding='utf-8'))
        if config['Global']['model_name'] != f'PP-OCRv6_{model["model"]}_{model["role"]}':
            raise ValueError('模型与固定配置不匹配')
        if all((destination / filename).is_file() for filename in model['files']):
            for filename in model['files']:
                if hashlib.sha256((destination / filename).read_bytes()).hexdigest() != model['fileSHA256'][filename]:
                    raise ValueError(f'本地模型损坏：{destination / filename}')
            print(f'已校验 {model["model"]}/{model["role"]}', flush=True)
            continue
        with tempfile.TemporaryDirectory(prefix='stock-ocr-') as work:
            archive = Path(work) / 'model.tar'
            print(f'下载 {model["model"]}/{model["role"]}', flush=True)
            urllib.request.urlretrieve(model['url'], archive)
            if hashlib.sha256(archive.read_bytes()).hexdigest() != model['sha256']:
                raise ValueError(f'模型下载校验失败：{model["url"]}')
            with tarfile.open(archive) as package:
                for filename in model['files']:
                    members = [m for m in package.getmembers() if m.isfile() and Path(m.name).name == filename]
                    if len(members) != 1 or filename != Path(filename).name:
                        raise ValueError(f'模型文件不存在或不唯一：{filename}')
                    stream = package.extractfile(members[0])
                    if stream is None:
                        raise ValueError(f'无法读取模型文件：{filename}')
                    destination.mkdir(parents=True, exist_ok=True)
                    binary = stream.read()
                    if hashlib.sha256(binary).hexdigest() != model['fileSHA256'][filename]:
                        raise ValueError(f'模型文件校验失败：{filename}')
                    # 临时目录可能在另一磁盘，使用目标目录上的临时文件后原子替换。
                    with tempfile.NamedTemporaryFile(dir=destination, prefix='.model-', delete=False) as target:
                        target.write(binary)
                        pending = Path(target.name)
                    os.replace(pending, destination / filename)


if __name__ == '__main__':
    main()
