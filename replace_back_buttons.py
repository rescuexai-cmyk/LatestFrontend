import os
import re

def find_dart_files(start_dir):
    dart_files = []
    for root, dirs, files in os.walk(start_dir):
        for file in files:
            if file.endswith('.dart'):
                dart_files.append(os.path.join(root, file))
    return dart_files

def process_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    original_content = content
    modified = False

    # Find the package name for imports
    import_stmt = "import 'package:raahi/core/widgets/figma_square_back_button.dart';"
    with open('pubspec.yaml', 'r') as pub:
        for line in pub:
            if line.startswith('name:'):
                pkg = line.split(':')[1].strip()
                import_stmt = f"import 'package:{pkg}/core/widgets/figma_square_back_button.dart';"
                break

    # 1. Replace IconButton regardless of param order
    # Look for IconButton(...) containing icon: const Icon(Icons.arrow_back...) and onPressed: ...
    # We will use re.sub with a custom function to parse the block
    def iconbutton_repl(match):
        block = match.group(0)
        if 'Icons.arrow_back' in block or 'CupertinoIcons.back' in block:
            # extract onPressed value
            onpressed_match = re.search(r'onPressed:\s*([^,]+),?', block)
            if onpressed_match:
                onpressed_val = onpressed_match.group(1).strip()
                return f'FigmaSquareBackButton(\n          onPressed: {onpressed_val},\n        )'
        return block

    new_content = re.sub(r'IconButton\([^)]+\)', iconbutton_repl, content, flags=re.DOTALL)
    if new_content != content:
        content = new_content
        modified = True

    # 2. Replace GestureDetector containing Icons.arrow_back
    def gesture_repl(match):
        block = match.group(0)
        if 'Icons.arrow_back' in block:
            onpressed_match = re.search(r'onTap:\s*([^,]+),?', block)
            if onpressed_match:
                onpressed_val = onpressed_match.group(1).strip()
                return f'FigmaSquareBackButton(\n          onPressed: {onpressed_val},\n        )'
        return block

    new_content = re.sub(r'GestureDetector\(\s*(?:onTap|child):[^)]+\)', gesture_repl, content, flags=re.DOTALL)
    # The above regex might not capture nested parens well.
    # Let's use a simpler string replacement for common ones:
    
    # Custom fallback for common GestureDetector
    content_lines = content.split('\n')
    i = 0
    while i < len(content_lines):
        line = content_lines[i]
        if 'child: const Icon(Icons.arrow_back' in line or 'child: Icon(Icons.arrow_back' in line:
            # Look backwards for GestureDetector and onTap
            j = i - 1
            ontap_val = None
            found_gesture = False
            while j >= max(0, i - 10):
                if 'onTap:' in content_lines[j]:
                    ontap_match = re.search(r'onTap:\s*([^,]+),?', content_lines[j])
                    if ontap_match:
                        ontap_val = ontap_match.group(1)
                if 'GestureDetector(' in content_lines[j]:
                    found_gesture = True
                    start_idx = j
                    break
                j -= 1
            
            if found_gesture and ontap_val:
                # find the end of the gesture detector (naively assumed to be a few lines down)
                k = i
                while k < min(len(content_lines), i + 5):
                    if '),' in content_lines[k]:
                        end_idx = k
                        # Replace start_idx to end_idx
                        replacement = f"FigmaSquareBackButton(onPressed: {ontap_val}),"
                        spaces = len(content_lines[start_idx]) - len(content_lines[start_idx].lstrip())
                        content_lines[start_idx] = (" " * spaces) + replacement
                        for idx in range(start_idx + 1, end_idx + 1):
                            content_lines[idx] = ""
                        modified = True
                        break
                    k += 1
        i += 1
    content = '\n'.join([l for l in content_lines if l != ""])

    if modified and 'FigmaSquareBackButton' not in original_content:
        if import_stmt not in content:
            lines = content.split('\n')
            last_import_idx = -1
            for idx, line in enumerate(lines):
                if line.startswith('import '):
                    last_import_idx = idx
            
            if last_import_idx != -1:
                lines.insert(last_import_idx + 1, import_stmt)
                content = '\n'.join(lines)
            else:
                content = import_stmt + '\n' + content

    if modified:
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"Updated {filepath}")

if __name__ == '__main__':
    dart_files = find_dart_files('lib')
    for f in dart_files:
        process_file(f)
