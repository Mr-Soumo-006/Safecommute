const { Client } = require('pg');

const client = new Client({
  connectionString: process.env.DATABASE_URL || 'postgresql://postgres:password@localhost:5432/safecommute',
});

const initDB = async () => {
  try {
    await client.connect();
    console.log('✅ [DATABASE] Connected to PostgreSQL Server!');

    // Ensure the PostGIS Extension is enabled for complex GPS math
    await client.query('CREATE EXTENSION IF NOT EXISTS postgis;');

    // Create the active_emergencies table with a Geospatial Point column
    await client.query(`
      CREATE TABLE IF NOT EXISTS active_emergencies (
        id SERIAL PRIMARY KEY,
        victim_id VARCHAR(255) NOT NULL,
        location GEOGRAPHY(Point, 4326), 
        last_updated TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        status VARCHAR(50) DEFAULT 'ACTIVE'
      );
    `);
    
    // Create the responder_network table for nearby civilians and police
    await client.query(`
      CREATE TABLE IF NOT EXISTS responder_network (
        id SERIAL PRIMARY KEY,
        responder_type VARCHAR(50) NOT NULL, -- 'POLICE' or 'CIVILIAN'
        last_known_location GEOGRAPHY(Point, 4326)
      );
    `);

    console.log('🌍 [DATABASE] PostGIS Geospatial Tables are ready for Phase 2!');
  } catch (err) {
    console.error('⚠️ [DATABASE] Setup failed. (Check your Supabase password!)');
    console.error(err.message);
  }
};

module.exports = { client, initDB };
