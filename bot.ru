import os
import logging
import asyncio
import base64
from aiogram import Bot, Dispatcher, types, F
from aiogram.filters import Command
from aiogram.fsm.context import FSMContext
from aiogram.fsm.state import State, StatesGroup
from aiogram.fsm.storage.memory import MemoryStorage
import google.generativeai as genai
from PIL import Image
import io
import httpx

logging.basicConfig(level=logging.INFO)

BOT_TOKEN = os.environ.get("BOT_TOKEN")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY")

genai.configure(api_key=GEMINI_API_KEY)

bot = Bot(token=BOT_TOKEN)
dp = Dispatcher(storage=MemoryStorage())

class FaceSwap(StatesGroup):
    waiting_face = State()
    waiting_target = State()

STYLES = {
    "viking": {"name": "🪓 Викинг", "prompt": "Place the person's face on a fierce Viking warrior with armor, fur cloak, dramatic nordic landscape background, photorealistic"},
    "samurai": {"name": "⚔️ Самурай", "prompt": "Place the person's face on a Japanese samurai warrior with traditional armor, cherry blossoms background, photorealistic"},
    "cyberpunk": {"name": "🤖 Киберпанк", "prompt": "Place the person's face in a cyberpunk setting, neon lights, futuristic city background, cybernetic implants, photorealistic"},
    "business": {"name": "💼 Бизнесмен", "prompt": "Place the person's face on a successful businessman in expensive suit, office background, photorealistic"},
    "marvel": {"name": "🦸 Супергерой", "prompt": "Place the person's face on a Marvel superhero with suit and cape, dramatic sky background, photorealistic"},
}

FACE_SWAP_PROMPT = """Image 1 is the IDENTITY SOURCE — extract only the face from this image.
Image 2 is the TARGET SCENE — keep everything: body, pose, clothing, lighting, background.
Replace the face in Image 2 with the face from Image 1.
Match skin tone, texture, lighting direction, and shadows precisely.
Preserve natural skin pores and imperfections.
The result must look like a real unedited photograph."""

async def download_photo(file_id: str) -> bytes:
    file = await bot.get_file(file_id)
    url = f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file.file_path}"
    async with httpx.AsyncClient() as client:
        response = await client.get(url)
        return response.content

def bytes_to_pil(image_bytes: bytes) -> Image.Image:
    return Image.open(io.BytesIO(image_bytes))

@dp.message(Command("start"))
async def start(message: types.Message):
    keyboard = types.ReplyKeyboardMarkup(
        keyboard=[
            [types.KeyboardButton(text="🎨 Готовые стили")],
            [types.KeyboardButton(text="✏️ Режим художника")],
        ],
        resize_keyboard=True
    )
    await message.answer(
        "👋 Привет! Я создаю реалистичные AI-фото с твоим лицом.\n\n"
        "Выбери режим:",
        reply_markup=keyboard
    )

@dp.message(F.text == "🎨 Готовые стили")
async def show_styles(message: types.Message, state: FSMContext):
    buttons = [[types.KeyboardButton(text=v["name"])] for v in STYLES.values()]
    buttons.append([types.KeyboardButton(text="🔙 Назад")])
    keyboard = types.ReplyKeyboardMarkup(keyboard=buttons, resize_keyboard=True)
    await message.answer("Выбери стиль:", reply_markup=keyboard)

@dp.message(F.text.in_([v["name"] for v in STYLES.values()]))
async def style_selected(message: types.Message, state: FSMContext):
    style_key = next(k for k, v in STYLES.items() if v["name"] == message.text)
    await state.update_data(mode="style", style_key=style_key)
    await state.set_state(FaceSwap.waiting_face)
    await message.answer("📸 Отправь своё фото (чёткое фото лица, смотришь прямо в камеру)")

@dp.message(F.text == "✏️ Режим художника")
async def artist_mode(message: types.Message, state: FSMContext):
    await state.update_data(mode="artist")
    await state.set_state(FaceSwap.waiting_face)
    await message.answer("📸 Сначала отправь своё фото лица")

@dp.message(FaceSwap.waiting_face, F.photo)
async def got_face(message: types.Message, state: FSMContext):
    photo = message.photo[-1]
    face_bytes = await download_photo(photo.file_id)
    await state.update_data(face_bytes=face_bytes)
    
    data = await state.get_data()
    
    if data["mode"] == "style":
        await state.set_state(FaceSwap.waiting_target)
        style_name = STYLES[data["style_key"]]["name"]
        await message.answer(f"✅ Фото получено!\n\nТеперь отправь фото-шаблон куда вставить лицо для стиля {style_name}\n\nИли напиши /generate чтобы сгенерировать автоматически")
    else:
        await state.set_state(FaceSwap.waiting_target)
        await message.answer("✅ Фото получено!\n\nТеперь напиши промпт — опиши что хочешь получить (на английском для лучшего результата)")

@dp.message(FaceSwap.waiting_target, F.text)
async def got_prompt(message: types.Message, state: FSMContext):
    data = await state.get_data()
    if data["mode"] != "artist":
        return
    
    await state.update_data(custom_prompt=message.text)
    await message.answer("🎨 Генерирую... подожди 30-60 секунд")
    await generate_with_prompt(message, state)

@dp.message(FaceSwap.waiting_target, F.photo)
async def got_target(message: types.Message, state: FSMContext):
    photo = message.photo[-1]
    target_bytes = await download_photo(photo.file_id)
    await state.update_data(target_bytes=target_bytes)
    await message.answer("🎨 Генерирую... подожди 30-60 секунд")
    await generate_swap(message, state)

async def generate_swap(message: types.Message, state: FSMContext):
    data = await state.get_data()
    try:
        model = genai.GenerativeModel("gemini-2.0-flash-exp-image-generation")
        face_img = bytes_to_pil(data["face_bytes"])
        target_img = bytes_to_pil(data["target_bytes"])
        
        response = model.generate_content(
            [FACE_SWAP_PROMPT, face_img, target_img],
            generation_config=genai.GenerationConfig(response_modalities=["IMAGE", "TEXT"])
        )
        
        for part in response.candidates[0].content.parts:
            if part.inline_data:
                img_bytes = part.inline_data.data
                await message.answer_photo(
                    types.BufferedInputFile(img_bytes, filename="result.jpg"),
                    caption="✨ Готово!"
                )
                await state.clear()
                return
        
        await message.answer("❌ Не удалось сгенерировать. Попробуй другое фото.")
    except Exception as e:
        logging.error(f"Error: {e}")
        await message.answer(f"❌ Ошибка: {str(e)}")
    await state.clear()

async def generate_with_prompt(message: types.Message, state: FSMContext):
    data = await state.get_data()
    try:
        model = genai.GenerativeModel("gemini-2.0-flash-exp-image-generation")
        face_img = bytes_to_pil(data["face_bytes"])
        
        prompt = f"""Take the face from the provided photo.
{data['custom_prompt']}
The person must have exactly the same face as in the photo.
Photorealistic, high quality."""
        
        response = model.generate_content(
            [prompt, face_img],
            generation_config=genai.GenerationConfig(response_modalities=["IMAGE", "TEXT"])
        )
        
        for part in response.candidates[0].content.parts:
            if part.inline_data:
                img_bytes = part.inline_data.data
                await message.answer_photo(
                    types.BufferedInputFile(img_bytes, filename="result.jpg"),
                    caption="✨ Готово!"
                )
                await state.clear()
                return
        
        await message.answer("❌ Не удалось сгенерировать. Попробуй другое фото.")
    except Exception as e:
        logging.error(f"Error: {e}")
        await message.answer(f"❌ Ошибка: {str(e)}")
    await state.clear()

async def main():
    await dp.start_polling(bot)

if __name__ == "__main__":
    asyncio.run(main())

