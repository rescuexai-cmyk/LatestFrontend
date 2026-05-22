import os

def replace_in_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    original = content
    
    # 1. name_entry_screen.dart
    content = content.replace("""                    child: IconButton(
                      onPressed: _isLoading ? null : () => context.pop(),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),""", """                    child: FigmaSquareBackButton(
                      onPressed: _isLoading ? null : () => context.pop(),
                    ),""")
                    
    # 2. otp_verification_screen.dart
    content = content.replace("""                      onPressed: _isLoading ? null : () => context.pop(),
                      icon: const Icon(
                        Icons.arrow_back,
                        color: Colors.white,
                      ),""", """                      onPressed: _isLoading ? null : () => context.pop(),
                    )""")
    # Wait, the above will leave the IconButton opening. Let's do it better.
    
    # Just use regex with better DOTALL and non-greedy matching.
    import re
    # IconButton(...)
    content = re.sub(r'IconButton\(\s*onPressed:\s*([^,]+),\s*icon:\s*const\s*Icon\(\s*Icons\.arrow_back(?:_rounded)?(?:[^)]+)?\s*\),\s*\)', r'FigmaSquareBackButton(\n  onPressed: \1,\n)', content)
    content = re.sub(r'IconButton\(\s*icon:\s*const\s*Icon\(\s*Icons\.arrow_back(?:_rounded)?(?:[^)]+)?\s*\),\s*onPressed:\s*([^,]+),\s*\)', r'FigmaSquareBackButton(\n  onPressed: \1,\n)', content)
    
    # child: const Icon(Icons.arrow_back...)
    content = re.sub(r'child:\s*const\s*Icon\(\s*Icons\.arrow_back(?:_rounded)?(?:[^)]+)?\s*\)', r'child: FigmaSquareBackButton()', content)

    if content != original:
        # Check import
        import_stmt = "import '../../../../core/widgets/figma_square_back_button.dart';"
        if import_stmt not in content and 'FigmaSquareBackButton' in content:
            # find last import
            lines = content.split('\n')
            last_import = -1
            for i, l in enumerate(lines):
                if l.startswith('import '):
                    last_import = i
            if last_import != -1:
                lines.insert(last_import + 1, import_stmt)
            else:
                lines.insert(0, import_stmt)
            content = '\n'.join(lines)
            
        with open(filepath, 'w') as f:
            f.write(content)
        print(f"Updated {filepath}")

for root, _, files in os.walk('lib'):
    for file in files:
        if file.endswith('.dart'):
            replace_in_file(os.path.join(root, file))
