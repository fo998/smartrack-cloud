#include <WiFi.h>
#include <PubSubClient.h>
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <DHT.h>
#include <math.h>

// =============================================================
// SMART RACK - ESP32 + MQTT  ->  SERVIDOR EN LA NUBE (AWS)
// =============================================================
// Librerias adicionales: PubSubClient, DHT sensor library,
// Adafruit Unified Sensor, LiquidCrystal_I2C.
//
// CAMBIOS respecto a la version local (22-10-2026):
//  - MQTT_HOST ahora es el DOMINIO del servidor, no una IP de la casa.
//    Como el dominio se actualiza solo (DuckDNS), aunque la IP de AWS
//    cambie en cada sesion, el ESP32 vuelve a conectarse sin reprogramarlo.
//  - Usuario/clave MQTT deben ser los de config.env del servidor.
//  - Wi-Fi y claves quedan como marcadores: este archivo puede terminar
//    en un repositorio publico; escribe tus datos solo en tu copia local.
// El resto del programa (pines, topicos, logica de alarma) NO cambia.

// ----------------- RED -----------------
const char* WIFI_SSID = "TU_RED_WIFI";              // red 2.4 GHz
const char* WIFI_PASSWORD = "TU_CLAVE_WIFI";
const char* MQTT_HOST = "smartrack-grupo1.duckdns.org"; // = DOMINIO de config.env
const uint16_t MQTT_PORT = 1883;
const char* MQTT_USER = "fzeballos";                 // = MQTT_USUARIO de config.env
const char* MQTT_PASSWORD = "CambiaEstaClave2026";   // = MQTT_CLAVE de config.env

// ----------------- PINES -----------------
const uint8_t PIN_LED_ROJO = 2;
const uint8_t PIN_LED_VERDE = 4;
const uint8_t PIN_DHT = 18;
const uint8_t PIN_PUERTA = 19;
const uint8_t PIN_BUZZER = 13;
const uint8_t PIN_BOTON = 21;
const uint8_t PIN_LCD_SDA = 26;
const uint8_t PIN_LCD_SCL = 27;
const float UMBRAL_TEMP = 30.0f;

// Si la puerta indica el estado al reves, cambiar true por false.
const bool CONTACTO_CERRADO_CON_IMAN = true;

// Para buzzer pasivo usa true; para buzzer activo de 3.3 V, false.
// Verifica antes la corriente admisible del GPIO o usa transistor.
const bool BUZZER_PASIVO = true;

// ----------------- TOPICOS -----------------
const char* T_CONEXION       = "SmartRack/Estado/Conexion";
const char* T_IP             = "SmartRack/Estado/IP";
const char* T_JSON           = "SmartRack/Sensores/JSON";
const char* T_TEMPERATURA    = "SmartRack/Sensores/Temperatura";
const char* T_HUMEDAD        = "SmartRack/Sensores/Humedad";
const char* T_DHT_ESTADO     = "SmartRack/Sensores/DHT11/Estado";
const char* T_PUERTA         = "SmartRack/Sensores/Puerta";
const char* T_ROJO           = "SmartRack/Actuadores/LedRojo";
const char* T_VERDE          = "SmartRack/Actuadores/LedVerde";
const char* T_BUZZER         = "SmartRack/Actuadores/Buzzer";
const char* T_BOTON          = "SmartRack/Entradas/BotonFisico";
const char* T_BOTON_EVENTO   = "SmartRack/Eventos/BotonFisico";
const char* T_ALARMA         = "SmartRack/Alarmas/Estado";
const char* T_ALARMA_ORIGEN  = "SmartRack/Alarmas/UltimoSilenciadoPor";
const char* T_LCD1           = "SmartRack/Pantalla/Linea1";
const char* T_LCD2           = "SmartRack/Pantalla/Linea2";
const char* T_CONTROL_ALARMA = "SmartRack/Control/Alarma"; // Recibe APAGAR

WiFiClient wifiCliente;
PubSubClient mqtt(wifiCliente);
DHT dht(PIN_DHT, DHT11);
LiquidCrystal_I2C lcd(0x27, 16, 2);

float temperatura = NAN, humedad = NAN;
bool dhtValido = false;
bool temperaturaAlta = false;
bool alarmaActiva = false;
bool alarmaReconocida = false;
bool buzzerEncendido = false;
bool puertaCerrada = false;
bool botonPresionado = false;

bool ultimaLecturaPuerta = HIGH;
bool estadoEstablePuerta = HIGH;
unsigned long cambioPuertaMs = 0;
bool ultimaLecturaBoton = HIGH;
bool estadoEstableBoton = HIGH;
unsigned long cambioBotonMs = 0;

unsigned long ultimaLecturaDHT = 0;
unsigned long ultimaPublicacion = 0;
unsigned long ultimaLCD = 0;
unsigned long ultimoWiFi = 0;
unsigned long ultimoMQTT = 0;
bool primeraLecturaDHT = true;
bool estadoPorPublicar = true;
String linea1 = "", linea2 = "";

bool estadoPuertaCerrada(bool nivel) {
  return CONTACTO_CERRADO_CON_IMAN ? (nivel == LOW) : (nivel == HIGH);
}

void publicar(const char* topico, const String& valor, bool retenido = true) {
  if (mqtt.connected()) mqtt.publish(topico, valor.c_str(), retenido);
}

void actualizarSalidas() {
  digitalWrite(PIN_LED_ROJO, dhtValido && temperaturaAlta ? HIGH : LOW);
  digitalWrite(PIN_LED_VERDE, dhtValido && !temperaturaAlta ? HIGH : LOW);

  if (alarmaActiva != buzzerEncendido) {
    if (alarmaActiva) {
      if (BUZZER_PASIVO) tone(PIN_BUZZER, 1200);
      else digitalWrite(PIN_BUZZER, HIGH);
    } else {
      if (BUZZER_PASIVO) noTone(PIN_BUZZER);
      digitalWrite(PIN_BUZZER, LOW);
    }
    buzzerEncendido = alarmaActiva;
  }
}

void silenciarAlarma(const char* origen) {
  if (!alarmaActiva) return;
  alarmaActiva = false;
  alarmaReconocida = true; // No vuelve a sonar mientras persista el calor.
  actualizarSalidas();
  publicar(T_ALARMA_ORIGEN, origen);
  estadoPorPublicar = true;
  Serial.printf("Alarma silenciada desde: %s\n", origen);
}

void revisarPuertaYBoton() {
  unsigned long ahora = millis();

  bool p = digitalRead(PIN_PUERTA);
  if (p != ultimaLecturaPuerta) cambioPuertaMs = ahora;
  if (ahora - cambioPuertaMs >= 50 && p != estadoEstablePuerta) {
    estadoEstablePuerta = p;
    puertaCerrada = estadoPuertaCerrada(p);
    estadoPorPublicar = true;
    publicar(T_PUERTA, puertaCerrada ? "CERRADA" : "ABIERTA");
    Serial.printf("PUERTA: %s\n", puertaCerrada ? "CERRADA" : "ABIERTA");
  }
  ultimaLecturaPuerta = p;

  bool b = digitalRead(PIN_BOTON);
  if (b != ultimaLecturaBoton) cambioBotonMs = ahora;
  if (ahora - cambioBotonMs >= 50 && b != estadoEstableBoton) {
    estadoEstableBoton = b;
    botonPresionado = (b == LOW);
    publicar(T_BOTON, botonPresionado ? "PRESIONADO" : "LIBRE");
    estadoPorPublicar = true;
    if (botonPresionado) {
      publicar(T_BOTON_EVENTO, "PRESIONADO", false);
      Serial.println("BOTON FISICO PRESIONADO");
      silenciarAlarma("BOTON_FISICO");
    }
  }
  ultimaLecturaBoton = b;
}

void leerDHT11() {
  unsigned long ahora = millis();
  if (!primeraLecturaDHT && ahora - ultimaLecturaDHT < 2000) return;
  primeraLecturaDHT = false;
  ultimaLecturaDHT = ahora;

  float h = dht.readHumidity();
  float t = dht.readTemperature();
  if (isnan(h) || isnan(t)) {
    dhtValido = false;
    Serial.println("No se pudo leer el DHT11");
    actualizarSalidas();
    estadoPorPublicar = true;
    return;
  }

  humedad = h;
  temperatura = t;
  dhtValido = true;
  temperaturaAlta = temperatura >= UMBRAL_TEMP;

  if (temperaturaAlta && !alarmaReconocida) alarmaActiva = true;
  // Si ya fue silenciada, esperar a enfriar antes de rearmar.
  if (!temperaturaAlta && !alarmaActiva) alarmaReconocida = false;

  actualizarSalidas();
  estadoPorPublicar = true;
  Serial.printf("Temp: %.1f C | Hum: %.1f %% | Puerta: %s | Alarma: %s\n",
                temperatura, humedad, puertaCerrada ? "CERRADA" : "ABIERTA",
                alarmaActiva ? "ACTIVA" : "APAGADA");
}

void ponerLinea(uint8_t fila, const String& texto) {
  String ajustado = texto.substring(0, 16);
  while (ajustado.length() < 16) ajustado += ' ';
  lcd.setCursor(0, fila);
  lcd.print(ajustado);
}

void actualizarLCD() {
  // Alterna datos ambientales y puerta cada 3 segundos.
  bool vistaPuerta = ((millis() / 3000UL) % 2) == 1;
  if (!dhtValido) {
    linea1 = "DHT11 SIN DATOS";
  } else if (vistaPuerta) {
    linea1 = "Puerta: " + String(puertaCerrada ? "CERRADA" : "ABIERTA");
  } else {
    linea1 = "Temp: " + String(temperatura, 1) + " C";
  }

  if (alarmaActiva) linea2 = "ALARMA ACTIVA!";
  else if (!dhtValido) linea2 = "Revisar sensor";
  else if (vistaPuerta) linea2 = "Alarma: APAGADA";
  else linea2 = "Hum: " + String(humedad, 1) + " %";

  ponerLinea(0, linea1);
  ponerLinea(1, linea2);
}

String generarJSON() {
  String json;
  json.reserve(320);
  json = "{";
  json += "\"dhtValido\":" + String(dhtValido ? "true" : "false") + ",";
  json += "\"temperatura\":" + String(dhtValido ? String(temperatura, 1) : "null") + ",";
  json += "\"humedad\":" + String(dhtValido ? String(humedad, 1) : "null") + ",";
  json += "\"puerta\":\"" + String(puertaCerrada ? "CERRADA" : "ABIERTA") + "\",";
  json += "\"temperaturaAlta\":" + String(dhtValido && temperaturaAlta ? "true" : "false") + ",";
  json += "\"alarma\":" + String(alarmaActiva ? "true" : "false") + ",";
  json += "\"ledRojo\":" + String(dhtValido && temperaturaAlta ? "true" : "false") + ",";
  json += "\"ledVerde\":" + String(dhtValido && !temperaturaAlta ? "true" : "false") + ",";
  json += "\"buzzer\":" + String(buzzerEncendido ? "true" : "false") + ",";
  json += "\"botonFisico\":\"" + String(botonPresionado ? "PRESIONADO" : "LIBRE") + "\"";
  json += "}";
  return json;
}

void publicarEstado() {
  if (!mqtt.connected()) return;
  publicar(T_JSON, generarJSON());
  publicar(T_TEMPERATURA, dhtValido ? String(temperatura, 1) : "SIN_DATOS");
  publicar(T_HUMEDAD, dhtValido ? String(humedad, 1) : "SIN_DATOS");
  publicar(T_DHT_ESTADO, dhtValido ? "OK" : "ERROR");
  publicar(T_PUERTA, puertaCerrada ? "CERRADA" : "ABIERTA");
  publicar(T_ROJO, dhtValido && temperaturaAlta ? "ON" : "OFF");
  publicar(T_VERDE, dhtValido && !temperaturaAlta ? "ON" : "OFF");
  publicar(T_BUZZER, buzzerEncendido ? "ON" : "OFF");
  publicar(T_BOTON, botonPresionado ? "PRESIONADO" : "LIBRE");
  publicar(T_ALARMA, alarmaActiva ? "ACTIVA" : "APAGADA");
  publicar(T_LCD1, linea1);
  publicar(T_LCD2, linea2);
  estadoPorPublicar = false;
}

void recibirMQTT(char* topico, byte* carga, unsigned int largo) {
  if (strcmp(topico, T_CONTROL_ALARMA) != 0 || largo > 31) return;
  char comando[32];
  memcpy(comando, carga, largo);
  comando[largo] = '\0';
  String orden(comando);
  orden.trim();
  orden.toUpperCase();
  Serial.printf("MQTT recibido en %s: %s\n", topico, orden.c_str());
  if (orden == "APAGAR") silenciarAlarma("MQTT");
}

void mantenerWiFi() {
  if (WiFi.status() == WL_CONNECTED) return;
  unsigned long ahora = millis();
  if (ultimoWiFi != 0 && ahora - ultimoWiFi < 10000) return;
  ultimoWiFi = ahora;
  Serial.println("Conectando / recuperando Wi-Fi...");
  WiFi.disconnect();
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
}

void mantenerMQTT() {
  if (WiFi.status() != WL_CONNECTED) return;
  if (mqtt.connected()) return;
  unsigned long ahora = millis();
  if (ultimoMQTT != 0 && ahora - ultimoMQTT < 5000) return;
  ultimoMQTT = ahora;

  String id = "SmartRack-" + WiFi.macAddress();
  id.replace(":", "");
  Serial.print("Conectando a MQTT ");
  Serial.println(MQTT_HOST);
  if (mqtt.connect(id.c_str(), MQTT_USER, MQTT_PASSWORD,
                   T_CONEXION, 1, true, "DESCONECTADO")) {
    Serial.println("MQTT CONECTADO");
    mqtt.publish(T_CONEXION, "CONECTADO", true);
    publicar(T_IP, WiFi.localIP().toString());
    mqtt.subscribe(T_CONTROL_ALARMA);
    publicarEstado();
  } else {
    Serial.printf("Fallo MQTT, codigo: %d\n", mqtt.state());
  }
}

void setup() {
  Serial.begin(115200);
  pinMode(PIN_LED_ROJO, OUTPUT);
  pinMode(PIN_LED_VERDE, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);
  pinMode(PIN_BOTON, INPUT_PULLUP);
  pinMode(PIN_PUERTA, INPUT_PULLUP);
  digitalWrite(PIN_LED_ROJO, LOW);
  digitalWrite(PIN_LED_VERDE, LOW);
  digitalWrite(PIN_BUZZER, LOW);

  estadoEstablePuerta = ultimaLecturaPuerta = digitalRead(PIN_PUERTA);
  puertaCerrada = estadoPuertaCerrada(estadoEstablePuerta);
  estadoEstableBoton = ultimaLecturaBoton = digitalRead(PIN_BOTON);
  botonPresionado = (estadoEstableBoton == LOW);

  dht.begin();
  Wire.begin(PIN_LCD_SDA, PIN_LCD_SCL);
  lcd.init();
  lcd.backlight();
  ponerLinea(0, "SMART RACK IoT");
  ponerLinea(1, "Iniciando...");

  WiFi.mode(WIFI_STA);
  WiFi.setAutoReconnect(true);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);
  ultimoWiFi = millis();

  mqtt.setServer(MQTT_HOST, MQTT_PORT);
  mqtt.setCallback(recibirMQTT);
  mqtt.setBufferSize(512);
  mqtt.setKeepAlive(20);
  mqtt.setSocketTimeout(2);
  Serial.println("SmartRack iniciado. SIN servidor web; solo Wi-Fi + MQTT.");
  Serial.printf("Puerta inicial: %s\n", puertaCerrada ? "CERRADA" : "ABIERTA");
}

void loop() {
  revisarPuertaYBoton();
  leerDHT11();
  mantenerWiFi();
  mantenerMQTT();
  if (mqtt.connected()) mqtt.loop();

  unsigned long ahora = millis();
  if (ahora - ultimaLCD >= 500) {
    ultimaLCD = ahora;
    actualizarLCD();
  }
  if (estadoPorPublicar || ahora - ultimaPublicacion >= 2000) {
    if (mqtt.connected()) {
      ultimaPublicacion = ahora;
      publicarEstado();
    }
  }
  delay(5);
}