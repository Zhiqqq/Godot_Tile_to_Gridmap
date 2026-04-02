@tool
extends Control

signal build_button_pressed()
signal clear_button_pressed()

func _on_build_button_pressed() -> void:
	build_button_pressed.emit()

func _on_clear_button_pressed() -> void:
	clear_button_pressed.emit()
