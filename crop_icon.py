from PIL import Image
import os

def crop_image(input_path, output_path):
    try:
        img = Image.open(input_path)
        img = img.convert("RGBA")
        bbox = img.getbbox()
        if bbox:
            cropped_img = img.crop(bbox)
            # Add a small padding (optional, maybe 5%)
            # width, height = cropped_img.size
            # No, let's keep it tight as the user wants it BIG.
            # But specific icon requirements might need some padding. 
            # Android adaptive icons show the center 72dp of a 108dp circle.
            # So if we crop tight, we might want to place it on a larger canvas?
            # Actually, flutter_launcher_icons handles the generation. 
            # If we provide a tight image, it will be placed.
            # However, for adaptive icons, we usually provide a foreground that is 108x108.
            # If we just use image_path, it might be scaled.
            
            # Let's just crop it first.
            cropped_img.save(output_path)
            print(f"Cropped image saved to {output_path}")
        else:
            print("Image is empty or fully transparent")
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    crop_image(r"e:\Python_project\MirrorTradeMT5-3.0\trade_app_flutter\assets\icon.png", r"e:\Python_project\MirrorTradeMT5-3.0\trade_app_flutter\assets\icon_cropped.png")
